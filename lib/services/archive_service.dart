import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../models.dart';

/// Archive operations are in-memory and never extract paths to the filesystem.
/// A central-directory preflight runs before bounded, streaming inflation.
class ArchiveService {
  static const maxArchiveBytes = 256 * 1024 * 1024;
  static const maxEntryBytes = 32 * 1024 * 1024;
  static const maxUncompressedBytes = 256 * 1024 * 1024;
  static const maxPages = 500;
  static const maxEntries = 1200;
  static const maxManifestBytes = 2 * 1024 * 1024;

  MangaProject importCbz(Uint8List bytes, {String? title}) {
    final zip = _SafeZip(bytes);
    final files =
        zip.entries
            .where(
              (e) =>
                  !e.name.endsWith('/') &&
                  RegExp(
                    r'\.(png|jpe?g|webp)$',
                    caseSensitive: false,
                  ).hasMatch(e.name) &&
                  !e.name.startsWith('__MACOSX/') &&
                  !e.name.split('/').last.startsWith('._'),
            )
            .toList()
          ..sort((a, b) => naturalCompare(a.name, b.name));
    if (files.isEmpty || files.length > maxPages) {
      throw const FormatException(
        'Choose an archive containing 1–500 PNG, JPEG, or WebP pages.',
      );
    }
    final pages = <MangaPage>[];
    for (var index = 0; index < files.length; index++) {
      final entry = files[index];
      final content = zip.read(entry);
      final mime = imageMimeType(content);
      final extension = entry.name.split('.').last.toLowerCase();
      if ((mime == 'image/png' && extension != 'png') ||
          (mime == 'image/jpeg' && extension != 'jpg' && extension != 'jpeg') ||
          (mime == 'image/webp' && extension != 'webp')) {
        throw FormatException(
          'Image type does not match its filename: ${entry.name}',
        );
      }
      pages.add(
        MangaPage(
          id: 'page-${index + 1}',
          sourceName: entry.name,
          originalBytes: content,
          originalMimeType: mime,
        ),
      );
    }
    return MangaProject(
      title: title?.trim().isNotEmpty == true
          ? title!.trim()
          : 'Untitled manga',
      pages: pages,
    );
  }

  Uint8List exportCbz(MangaProject project) {
    if (!project.exportReady) {
      throw StateError(
        'Review an edited image or explicitly keep the original for every page before exporting.',
      );
    }
    _checkProject(project);
    final entries = <String, Uint8List>{};
    final records = <Map<String, Object>>[];
    for (var i = 0; i < project.pages.length; i++) {
      final page = project.pages[i];
      final filename =
          '${(i + 1).toString().padLeft(4, '0')}.${imageExtension(page.exportMimeType)}';
      entries[filename] = page.exportBytes;
      records.add({
        'page': i + 1,
        'filename': filename,
        'source_name': page.sourceName,
        'selection': page.keepOriginal
            ? 'original_kept_explicitly'
            : 'reviewed_edit',
        'transcript': page.transcript,
        'notes': page.notes,
      });
    }
    final originalCount = project.pages.where((p) => p.keepOriginal).length;
    final summary =
        'Exported with Ultimate Manga Tools. Every page was reviewed or '
        'explicitly kept as original. Original pages retained: $originalCount. '
        'See translation-notes.json for page-level translation and redaction notes.';
    entries['ComicInfo.xml'] = Uint8List.fromList(
      utf8.encode(
        '<?xml version="1.0" encoding="utf-8"?>\n<ComicInfo>\n'
        '  <Title>${_xml(project.title)}</Title>\n'
        '  <PageCount>${project.pages.length}</PageCount>\n'
        '  <LanguageISO>${_xml(project.targetLanguage)}</LanguageISO>\n'
        '  <Manga>YesAndRightToLeft</Manga>\n'
        '  <Notes>${_xml(summary)}</Notes>\n</ComicInfo>\n',
      ),
    );
    entries['translation-notes.json'] = _jsonBytes({
      'format': 'ultimate-manga-tools-notes',
      'version': 1,
      'title': project.title,
      'source_language': project.sourceLanguage,
      'target_language': project.targetLanguage,
      'glossary': project.glossary,
      'pages': records,
    });
    return _encodeZip(entries);
  }

  Uint8List saveProject(MangaProject project) {
    _checkProject(project);
    final entries = <String, Uint8List>{};
    final pages = <Map<String, Object?>>[];
    for (var i = 0; i < project.pages.length; i++) {
      final page = project.pages[i];
      final stem = 'pages/${(i + 1).toString().padLeft(4, '0')}';
      final original =
          '$stem.original.${imageExtension(page.originalMimeType)}';
      final edited = page.editedBytes == null
          ? null
          : '$stem.edited.${imageExtension(page.editedMimeType!)}';
      entries[original] = page.originalBytes;
      if (edited != null) entries[edited] = page.editedBytes!;
      pages.add({
        'id': page.id,
        'source_name': page.sourceName,
        'original': original,
        'edited': edited,
        'transcript': page.transcript,
        'notes': page.notes,
        'reviewed': page.reviewed,
        'keep_original': page.keepOriginal,
      });
    }
    entries['manifest.json'] = _jsonBytes({
      'format': 'ultimate-manga-tools-project',
      'version': 1,
      'title': project.title,
      'source_language': project.sourceLanguage,
      'target_language': project.targetLanguage,
      'glossary': project.glossary,
      'pages': pages,
    });
    return _encodeZip(entries);
  }

  MangaProject openProject(Uint8List bytes) {
    final zip = _SafeZip(bytes);
    final byName = {for (final entry in zip.entries) entry.name: entry};
    final manifest = byName['manifest.json'];
    if (manifest == null || manifest.size > maxManifestBytes) {
      throw const FormatException('This is not a supported .umt project.');
    }
    final dynamic data = jsonDecode(utf8.decode(zip.read(manifest)));
    if (data is! Map<String, dynamic> ||
        data['format'] != 'ultimate-manga-tools-project' ||
        data['version'] != 1) {
      throw const FormatException('Unsupported project format or version.');
    }
    final records = data['pages'];
    if (records is! List || records.isEmpty || records.length > maxPages) {
      throw const FormatException('A project must contain 1–500 pages.');
    }
    final ids = <String>{};
    final usedFiles = <String>{'manifest.json'};
    Uint8List readImage(String path) {
      if (!usedFiles.add(path) ||
          !path.startsWith('pages/') ||
          byName[path] == null) {
        throw const FormatException(
          'Project contains a missing or reused page image.',
        );
      }
      return zip.read(byName[path]!);
    }

    final pages = <MangaPage>[];
    for (final record in records) {
      if (record is! Map<String, dynamic>)
        throw const FormatException('Invalid project page.');
      final id = _string(record, 'id', 200);
      if (id.isEmpty || !ids.add(id))
        throw const FormatException('Duplicate or empty page ID.');
      final originalBytes = readImage(_string(record, 'original', 1024));
      final page = MangaPage(
        id: id,
        sourceName: _string(record, 'source_name', 1024),
        originalBytes: originalBytes,
        originalMimeType: imageMimeType(originalBytes),
      );
      page.transcript = _string(record, 'transcript', 100000);
      page.notes = _string(record, 'notes', 100000);
      if (record['edited'] != null) {
        final editedBytes = readImage(_string(record, 'edited', 1024));
        page.setEdited(
          editedBytes,
          imageMimeType(editedBytes),
          notes: page.notes,
        );
      }
      if (record['reviewed'] is! bool || record['keep_original'] is! bool) {
        throw const FormatException('Invalid page review status.');
      }
      page.reviewed = record['reviewed'] as bool;
      page.keepOriginal = record['keep_original'] as bool;
      if (page.reviewed && (page.editedBytes == null || page.keepOriginal)) {
        throw const FormatException('Inconsistent page review status.');
      }
      pages.add(page);
    }
    return MangaProject(
      title: _string(data, 'title', 1000),
      pages: pages,
      sourceLanguage: _string(data, 'source_language', 100),
      targetLanguage: _string(data, 'target_language', 100),
      glossary: _string(data, 'glossary', 10000),
    );
  }

  void _checkProject(MangaProject project) {
    if (project.pages.isEmpty || project.pages.length > maxPages) {
      throw const FormatException('A project must contain 1–500 pages.');
    }
    if (project.title.length > 1000 ||
        project.glossary.length > 10000 ||
        project.sourceLanguage.length > 100 ||
        project.targetLanguage.length > 100) {
      throw const FormatException(
        'Project settings exceed the supported text limits.',
      );
    }
    final ids = <String>{};
    for (final page in project.pages) {
      if (page.id.isEmpty ||
          page.id.length > 200 ||
          !ids.add(page.id) ||
          page.sourceName.length > 1024 ||
          page.transcript.length > 100000 ||
          page.notes.length > 100000) {
        throw const FormatException('Page metadata is invalid or too large.');
      }
      if (imageMimeType(page.originalBytes) != page.originalMimeType ||
          (page.editedBytes != null &&
              imageMimeType(page.editedBytes!) != page.editedMimeType)) {
        throw const FormatException(
          'Page MIME type does not match image contents.',
        );
      }
      if (page.reviewed && (page.editedBytes == null || page.keepOriginal)) {
        throw const FormatException('Page has inconsistent review status.');
      }
    }
  }
}

int naturalCompare(String left, String right) {
  final tokens = RegExp(r'\d+|\D+');
  final a = tokens.allMatches(left.toLowerCase()).map((m) => m[0]!).toList();
  final b = tokens.allMatches(right.toLowerCase()).map((m) => m[0]!).toList();
  for (var i = 0; i < math.min(a.length, b.length); i++) {
    final x = a[i], y = b[i];
    int result;
    if (RegExp(r'^\d').hasMatch(x) && RegExp(r'^\d').hasMatch(y)) {
      final nx = x.replaceFirst(RegExp(r'^0+'), '');
      final ny = y.replaceFirst(RegExp(r'^0+'), '');
      result = nx.length.compareTo(ny.length);
      if (result == 0) result = nx.compareTo(ny);
      if (result == 0) result = x.length.compareTo(y.length);
    } else {
      result = x.compareTo(y);
    }
    if (result != 0) return result;
  }
  final count = a.length.compareTo(b.length);
  return count != 0 ? count : left.compareTo(right);
}

String _string(Map<String, dynamic> object, String key, int maxLength) {
  final value = object[key];
  if (value is! String || value.length > maxLength)
    throw FormatException('Invalid project field: $key');
  return value;
}

String _xml(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

Uint8List _jsonBytes(Map<String, Object?> value) {
  final bytes = Uint8List.fromList(
    utf8.encode(const JsonEncoder.withIndent('  ').convert(value)),
  );
  if (bytes.length > ArchiveService.maxManifestBytes) {
    throw const FormatException(
      'Project text exceeds the 2 MiB metadata limit.',
    );
  }
  return bytes;
}

class _ZipEntry {
  const _ZipEntry(
    this.name,
    this.offset,
    this.compressedSize,
    this.size,
    this.method,
    this.crc,
  );
  final String name;
  final int offset, compressedSize, size, method, crc;
}

class _SafeZip {
  _SafeZip(this.bytes) {
    if (bytes.length < 22 || bytes.length > ArchiveService.maxArchiveBytes) {
      throw const FormatException('Archive is invalid or larger than 256 MiB.');
    }
    final view = ByteData.sublistView(bytes);
    int u16(int offset) => view.getUint16(offset, Endian.little);
    int u32(int offset) => view.getUint32(offset, Endian.little);
    var end = -1;
    for (
      var i = bytes.length - 22;
      i >= math.max(0, bytes.length - 65557);
      i--
    ) {
      if (u32(i) == 0x06054b50 && i + 22 + u16(i + 20) == bytes.length) {
        end = i;
        break;
      }
    }
    if (end < 0)
      throw const FormatException('Archive has no valid ZIP directory.');
    final count = u16(end + 10);
    final directorySize = u32(end + 12), directoryOffset = u32(end + 16);
    if (u16(end + 4) != 0 ||
        u16(end + 6) != 0 ||
        u16(end + 8) != count ||
        count == 0xffff ||
        count > ArchiveService.maxEntries ||
        directoryOffset + directorySize != end) {
      throw const FormatException(
        'Multi-volume, ZIP64, or oversized archives are not supported.',
      );
    }
    final names = <String>{};
    final ranges = <(int, int)>[];
    var cursor = directoryOffset;
    var total = 0;
    for (var i = 0; i < count; i++) {
      if (cursor + 46 > end || u32(cursor) != 0x02014b50) {
        throw const FormatException('Archive directory is damaged.');
      }
      final flags = u16(cursor + 8), method = u16(cursor + 10);
      final crc = u32(cursor + 16),
          compressed = u32(cursor + 20),
          size = u32(cursor + 24);
      final nameLength = u16(cursor + 28),
          extraLength = u16(cursor + 30),
          commentLength = u16(cursor + 32);
      final local = u32(cursor + 42), external = u32(cursor + 38);
      final next = cursor + 46 + nameLength + extraLength + commentLength;
      if (next > end ||
          nameLength == 0 ||
          nameLength > 4096 ||
          (flags & ~0x080e) != 0 ||
          (method != 0 && method != 8) ||
          u16(cursor + 34) != 0 ||
          ((external >> 16) & 0xf000) == 0xa000) {
        throw const FormatException(
          'Encrypted, linked, or unsupported ZIP entries are not allowed.',
        );
      }
      final nameBytes = Uint8List.sublistView(
        bytes,
        cursor + 46,
        cursor + 46 + nameLength,
      );
      final name = (flags & 0x800) != 0
          ? utf8.decode(nameBytes)
          : latin1.decode(nameBytes);
      _validateName(name);
      if (!names.add(name.toLowerCase()))
        throw const FormatException('Duplicate archive paths are not allowed.');
      if (size > ArchiveService.maxEntryBytes ||
          compressed > ArchiveService.maxEntryBytes ||
          (size > 0 && compressed == 0) ||
          (compressed > 0 && size / compressed > 200) ||
          (method == 0 && size != compressed)) {
        throw const FormatException(
          'Archive entry exceeds size or compression limits.',
        );
      }
      total += size;
      if (total > ArchiveService.maxUncompressedBytes) {
        throw const FormatException('Expanded archive exceeds 256 MiB.');
      }
      if (local + 30 > directoryOffset ||
          u32(local) != 0x04034b50 ||
          u16(local + 6) != flags ||
          u16(local + 8) != method) {
        throw const FormatException(
          'Archive local header does not match its directory.',
        );
      }
      final localNameLength = u16(local + 26),
          localExtraLength = u16(local + 28);
      final contentOffset = local + 30 + localNameLength + localExtraLength;
      if (contentOffset + compressed > directoryOffset ||
          localNameLength != nameLength) {
        throw const FormatException(
          'Archive entry lies outside its data region.',
        );
      }
      for (var n = 0; n < nameLength; n++) {
        if (bytes[local + 30 + n] != nameBytes[n]) {
          throw const FormatException(
            'Archive filename differs between headers.',
          );
        }
      }
      if ((flags & 8) == 0 &&
          (u32(local + 14) != crc ||
              u32(local + 18) != compressed ||
              u32(local + 22) != size)) {
        throw const FormatException('Archive sizes differ between headers.');
      }
      if (name.endsWith('/') && size != 0)
        throw const FormatException('Archive directory contains file data.');
      ranges.add((local, contentOffset + compressed));
      entries.add(
        _ZipEntry(name, contentOffset, compressed, size, method, crc),
      );
      cursor = next;
    }
    if (cursor != end)
      throw const FormatException('Archive directory length is inconsistent.');
    ranges.sort((a, b) => a.$1.compareTo(b.$1));
    for (var i = 1; i < ranges.length; i++) {
      if (ranges[i].$1 < ranges[i - 1].$2)
        throw const FormatException('Overlapping ZIP entries are not allowed.');
    }
  }

  final Uint8List bytes;
  final List<_ZipEntry> entries = [];

  Uint8List read(_ZipEntry entry) {
    final compressed = Uint8List.sublistView(
      bytes,
      entry.offset,
      entry.offset + entry.compressedSize,
    );
    Uint8List result;
    if (entry.method == 0) {
      result = Uint8List.fromList(compressed);
    } else {
      final sink = _BoundedSink(entry.size);
      try {
        final decoder = ZLibDecoder(raw: true).startChunkedConversion(sink);
        for (var offset = 0; offset < compressed.length; offset += 1024) {
          decoder.add(
            Uint8List.sublistView(
              compressed,
              offset,
              math.min(offset + 1024, compressed.length),
            ),
          );
        }
        decoder.close();
        result = sink.bytes.takeBytes();
      } on FormatException {
        rethrow;
      } catch (_) {
        throw const FormatException(
          'Archive contains invalid compressed data.',
        );
      }
    }
    if (result.length != entry.size || _crc32(result) != entry.crc) {
      throw FormatException(
        'Archive page failed its integrity check: ${entry.name}',
      );
    }
    return result;
  }
}

class _BoundedSink implements Sink<List<int>> {
  _BoundedSink(this.limit);
  final int limit;
  final bytes = BytesBuilder(copy: false);
  @override
  void add(List<int> data) {
    if (bytes.length + data.length > limit) {
      throw const FormatException(
        'Expanded ZIP data exceeds its declared size.',
      );
    }
    bytes.add(data);
  }

  @override
  void close() {}
}

void _validateName(String name) {
  final parts = name.split('/');
  if (name.startsWith('/') ||
      name.contains('\\') ||
      name.contains(':') ||
      name.codeUnits.any((c) => c < 32 || c == 127) ||
      parts.any((p) => p == '.' || p == '..') ||
      parts.take(parts.length - 1).any((p) => p.isEmpty)) {
    throw const FormatException('Unsafe archive paths are not allowed.');
  }
}

/// Stored ZIP entries keep image compression intact and make exports stable.
Uint8List _encodeZip(Map<String, Uint8List> files) {
  final output = BytesBuilder(copy: false),
      directory = BytesBuilder(copy: false);
  var total = 0;
  for (final file in files.entries) {
    _validateName(file.key);
    final name = utf8.encode(file.key), content = file.value;
    total += content.length;
    if (content.length > ArchiveService.maxEntryBytes ||
        total > ArchiveService.maxUncompressedBytes) {
      throw const FormatException(
        'Project images exceed the 256 MiB archive limit.',
      );
    }
    final crc = _crc32(content), offset = output.length;
    final local = ByteData(30)
      ..setUint32(0, 0x04034b50, Endian.little)
      ..setUint16(4, 20, Endian.little)
      ..setUint16(6, 0x800, Endian.little)
      ..setUint16(12, 33, Endian.little)
      ..setUint32(14, crc, Endian.little)
      ..setUint32(18, content.length, Endian.little)
      ..setUint32(22, content.length, Endian.little)
      ..setUint16(26, name.length, Endian.little);
    output.add(local.buffer.asUint8List());
    output.add(name);
    output.add(content);
    final central = ByteData(46)
      ..setUint32(0, 0x02014b50, Endian.little)
      ..setUint16(4, 20, Endian.little)
      ..setUint16(6, 20, Endian.little)
      ..setUint16(8, 0x800, Endian.little)
      ..setUint16(14, 33, Endian.little)
      ..setUint32(16, crc, Endian.little)
      ..setUint32(20, content.length, Endian.little)
      ..setUint32(24, content.length, Endian.little)
      ..setUint16(28, name.length, Endian.little)
      ..setUint32(42, offset, Endian.little);
    directory.add(central.buffer.asUint8List());
    directory.add(name);
  }
  final directoryOffset = output.length, directorySize = directory.length;
  output.add(directory.takeBytes());
  final end = ByteData(22)
    ..setUint32(0, 0x06054b50, Endian.little)
    ..setUint16(8, files.length, Endian.little)
    ..setUint16(10, files.length, Endian.little)
    ..setUint32(12, directorySize, Endian.little)
    ..setUint32(16, directoryOffset, Endian.little);
  output.add(end.buffer.asUint8List());
  if (output.length > ArchiveService.maxArchiveBytes) {
    throw const FormatException('Archive exceeds the 256 MiB file limit.');
  }
  return output.takeBytes();
}

final _crcTable = List<int>.generate(256, (index) {
  var value = index;
  for (var i = 0; i < 8; i++) {
    value = (value & 1) != 0 ? 0xedb88320 ^ (value >> 1) : value >> 1;
  }
  return value;
});

int _crc32(List<int> bytes) {
  var crc = 0xffffffff;
  for (final byte in bytes) {
    crc = _crcTable[(crc ^ byte) & 0xff] ^ (crc >> 8);
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}
