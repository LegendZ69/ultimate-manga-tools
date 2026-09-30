import 'dart:typed_data';

/// A project contains only document data. Service addresses and credentials are
/// intentionally session-only and are never part of a project checkpoint.
class MangaProject {
  MangaProject({
    required this.title,
    required this.pages,
    this.sourceLanguage = 'ja',
    this.targetLanguage = 'en',
    this.glossary = '',
  });

  String title;
  final List<MangaPage> pages;
  String sourceLanguage;
  String targetLanguage;
  String glossary;

  bool get exportReady => pages.isNotEmpty && pages.every((p) => p.exportReady);
  int get reviewedCount => pages.where((p) => p.exportReady).length;
}

class MangaPage {
  MangaPage({
    required this.id,
    required this.sourceName,
    required this.originalBytes,
    required this.originalMimeType,
  });

  final String id;
  final String sourceName;
  final Uint8List originalBytes;
  final String originalMimeType;
  Uint8List? editedBytes;
  String? editedMimeType;
  String transcript = '';
  String notes = '';
  bool reviewed = false;
  bool keepOriginal = false;

  bool get exportReady => keepOriginal || (reviewed && editedBytes != null);
  Uint8List get displayBytes => editedBytes ?? originalBytes;
  String get displayMimeType => editedMimeType ?? originalMimeType;
  Uint8List get exportBytes => keepOriginal ? originalBytes : editedBytes!;
  String get exportMimeType =>
      keepOriginal ? originalMimeType : editedMimeType!;

  void setTranscript(String value) {
    if (transcript != value) reviewed = false;
    transcript = value;
  }

  void setEdited(Uint8List bytes, String mimeType, {String notes = ''}) {
    if (imageMimeType(bytes) != mimeType) {
      throw const FormatException(
        'Image contents do not match their MIME type.',
      );
    }
    editedBytes = bytes;
    editedMimeType = mimeType;
    this.notes = notes;
    reviewed = false;
    keepOriginal = false;
  }

  void markReviewed() {
    if (editedBytes == null) {
      throw StateError(
        'Import or generate an edited image before reviewing it.',
      );
    }
    keepOriginal = false;
    reviewed = true;
  }

  void useOriginal(bool value) {
    keepOriginal = value;
    reviewed = false;
  }
}

class InpaintResult {
  const InpaintResult(this.bytes, this.mimeType, this.notes);
  final Uint8List bytes;
  final String mimeType;
  final String notes;
}

String imageExtension(String mimeType) => switch (mimeType) {
  'image/png' => 'png',
  'image/jpeg' => 'jpg',
  'image/webp' => 'webp',
  _ => throw const FormatException('Only PNG, JPEG, and WebP are supported.'),
};

/// Check signatures and declared dimensions before sending images to decoders.
/// Pixel limits also prevent a tiny compressed image allocating huge previews.
String imageMimeType(
  Uint8List bytes, {
  int maxImageBytes = 32 * 1024 * 1024,
  int maxPixels = 40000000,
  int maxDimension = 16000,
}) {
  if (bytes.isEmpty || bytes.length > maxImageBytes) {
    throw FormatException(
      'Image exceeds the ${maxImageBytes ~/ (1024 * 1024)} MiB size limit.',
    );
  }
  final data = ByteData.sublistView(bytes);
  void dimensions(int width, int height) {
    if (width < 1 ||
        height < 1 ||
        width > maxDimension ||
        height > maxDimension ||
        width * height > maxPixels) {
      throw FormatException(
        'Image exceeds the ${maxPixels ~/ 1000000} megapixel / $maxDimension pixel dimension limit.',
      );
    }
  }

  if (bytes.length >= 33 &&
      bytes[0] == 137 &&
      bytes[1] == 80 &&
      bytes[2] == 78 &&
      bytes[3] == 71 &&
      bytes[4] == 13 &&
      bytes[5] == 10 &&
      bytes[6] == 26 &&
      bytes[7] == 10 &&
      data.getUint32(8) == 13 &&
      data.getUint32(12) == 0x49484452) {
    dimensions(data.getUint32(16), data.getUint32(20));
    return 'image/png';
  }
  if (bytes.length >= 4 && bytes[0] == 0xff && bytes[1] == 0xd8) {
    var offset = 2;
    while (offset + 3 < bytes.length) {
      if (bytes[offset++] != 0xff) break;
      while (offset < bytes.length && bytes[offset] == 0xff) {
        offset++;
      }
      if (offset >= bytes.length) break;
      final marker = bytes[offset++];
      if (marker == 0xd9 || marker == 0xda) break;
      if (marker == 0x01 || (marker >= 0xd0 && marker <= 0xd7)) continue;
      if (offset + 2 > bytes.length) break;
      final length = data.getUint16(offset);
      if (length < 2 || offset + length > bytes.length) break;
      const frameMarkers = {
        0xc0,
        0xc1,
        0xc2,
        0xc3,
        0xc5,
        0xc6,
        0xc7,
        0xc9,
        0xca,
        0xcb,
        0xcd,
        0xce,
        0xcf,
      };
      if (frameMarkers.contains(marker) && length >= 8) {
        dimensions(data.getUint16(offset + 5), data.getUint16(offset + 3));
        return 'image/jpeg';
      }
      offset += length;
    }
    throw const FormatException('JPEG has no readable image frame.');
  }
  if (bytes.length >= 25 &&
      data.getUint32(0) == 0x52494646 &&
      data.getUint32(8) == 0x57454250) {
    final kind = data.getUint32(12);
    if (kind == 0x56503858 && bytes.length >= 30) {
      // VP8X
      int read24(int i) => bytes[i] | bytes[i + 1] << 8 | bytes[i + 2] << 16;
      dimensions(read24(24) + 1, read24(27) + 1);
    } else if (kind == 0x5650384c && bytes[20] == 0x2f) {
      // VP8L
      final bits = data.getUint32(21, Endian.little);
      dimensions((bits & 0x3fff) + 1, ((bits >> 14) & 0x3fff) + 1);
    } else if (kind == 0x56503820 &&
        bytes.length >= 30 &&
        bytes[23] == 0x9d &&
        bytes[24] == 0x01 &&
        bytes[25] == 0x2a) {
      dimensions(
        data.getUint16(26, Endian.little) & 0x3fff,
        data.getUint16(28, Endian.little) & 0x3fff,
      );
    } else {
      throw const FormatException('WebP has no readable image frame.');
    }
    return 'image/webp';
  }
  throw const FormatException(
    'Unsupported image. Choose a PNG, JPEG, or WebP.',
  );
}
