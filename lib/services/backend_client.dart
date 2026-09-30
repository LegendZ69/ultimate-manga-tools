import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models.dart';

class BackendException implements Exception {
  const BackendException(this.message, [this.statusCode]);
  final String message;
  final int? statusCode;
  @override
  String toString() => message;
}

/// Session-only connection to the user's service. No provider key is accepted
/// or stored by the application, and no paid request is retried automatically.
class BackendClient {
  BackendClient({
    required String baseUrl,
    required String token,
    http.Client? client,
  }) : _baseUri = validateBaseUrl(baseUrl),
       _token = token.trim(),
       _client = client ?? http.Client();

  final Uri _baseUri;
  final String _token;
  final http.Client _client;
  bool _closed = false;

  static Uri validateBaseUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const FormatException(
        'Enter a service URL without credentials, query, or fragment.',
      );
    }
    const loopback = {'localhost', '127.0.0.1', '::1', '[::1]'};
    if (uri.scheme != 'https' &&
        !(uri.scheme == 'http' && loopback.contains(uri.host.toLowerCase()))) {
      throw const FormatException(
        'Use HTTPS, or HTTP on localhost for development.',
      );
    }
    return uri.replace(path: uri.path.replaceFirst(RegExp(r'/+$'), ''));
  }

  Future<void> health() async {
    final result = await _request(
      'GET',
      '/health',
      timeout: const Duration(seconds: 20),
    );
    if (result['status'] != 'ok') {
      throw const BackendException(
        'The service did not report a healthy status.',
      );
    }
    if (result['ai_configured'] == false) {
      throw const BackendException(
        'Service is online, but its AI provider is not configured.',
      );
    }
  }

  Future<String> transcribe(MangaPage page, MangaProject project) async {
    final result = await _request(
      'POST',
      '/v1/transcribe',
      body: _imageBody(page, project),
    );
    final transcript = result['transcript'];
    if (transcript is! String ||
        transcript.trim().isEmpty ||
        transcript.length > 40000) {
      throw const BackendException(
        'The service returned an invalid transcript.',
      );
    }
    return transcript;
  }

  Future<InpaintResult> inpaint(MangaPage page, MangaProject project) async {
    if (page.transcript.trim().isEmpty) {
      throw const BackendException(
        'Add or generate an English transcript before inpainting.',
      );
    }
    final result = await _request(
      'POST',
      '/v1/inpaint',
      body: {..._imageBody(page, project), 'transcript': page.transcript},
      timeout: const Duration(minutes: 12),
    );
    final encoded = result['image_base64'];
    final mimeType = result['mime_type'];
    if (encoded is! String ||
        mimeType is! String ||
        encoded.length > 45000000) {
      throw const BackendException(
        'The service returned an invalid image response.',
      );
    }
    try {
      final bytes = base64Decode(encoded);
      if (imageMimeType(bytes) != mimeType) {
        throw const FormatException(
          'The returned image MIME type is incorrect.',
        );
      }
      final notes = result['notes'];
      final noteText = notes is List
          ? notes.whereType<String>().join('\n')
          : notes is String
          ? notes
          : '';
      return InpaintResult(bytes, mimeType, noteText);
    } on FormatException {
      throw const BackendException(
        'The service returned invalid or oversized image data.',
      );
    }
  }

  Map<String, Object> _imageBody(MangaPage page, MangaProject project) {
    if (imageMimeType(
          page.originalBytes,
          maxImageBytes: 12 * 1024 * 1024,
          maxPixels: 20000000,
          maxDimension: 12000,
        ) !=
        page.originalMimeType) {
      throw const BackendException(
        'The source image has an invalid MIME type.',
      );
    }
    if (project.glossary.length > 10000 || page.transcript.length > 40000) {
      throw const BackendException(
        'Glossary or transcript exceeds the service limit.',
      );
    }
    if ([
      project.sourceLanguage,
      project.targetLanguage,
    ].any((value) => value.trim().isEmpty || value.length > 64)) {
      throw const BackendException(
        'Source and target languages must contain 1–64 characters.',
      );
    }
    return {
      'image_base64': base64Encode(page.originalBytes),
      'mime_type': page.originalMimeType,
      'glossary': project.glossary,
      'source_language': project.sourceLanguage,
      'target_language': project.targetLanguage,
    };
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, Object>? body,
    Duration timeout = const Duration(minutes: 5),
  }) async {
    if (_closed)
      throw const BackendException('The service connection was closed.');
    final uri = _baseUri.replace(path: '${_baseUri.path}$path');
    final request = http.Request(method, uri)
      ..followRedirects = false
      ..headers['Accept'] = 'application/json';
    if (_token.isNotEmpty) request.headers['Authorization'] = 'Bearer $_token';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    try {
      return await (() async {
        final response = await _client.send(request);
        const limit = 48 * 1024 * 1024;
        if ((response.contentLength ?? 0) > limit) {
          throw const BackendException('The service response is too large.');
        }
        final buffer = BytesBuilder(copy: false);
        await for (final chunk in response.stream) {
          if (buffer.length + chunk.length > limit) {
            throw const BackendException('The service response is too large.');
          }
          buffer.add(chunk);
        }
        dynamic result;
        try {
          result = jsonDecode(utf8.decode(buffer.takeBytes()));
        } on FormatException {
          throw BackendException(
            'The service returned an unreadable response (${response.statusCode}).',
            response.statusCode,
          );
        }
        if (response.statusCode < 200 || response.statusCode >= 300) {
          final detail = result is Map ? result['detail'] : null;
          final message = detail is String && detail.length <= 500
              ? detail
              : 'Service request failed (${response.statusCode}).';
          throw BackendException(message, response.statusCode);
        }
        if (result is! Map<String, dynamic>) {
          throw const BackendException(
            'The service returned an invalid response object.',
          );
        }
        return result;
      })().timeout(timeout);
    } on TimeoutException {
      throw const BackendException(
        'The service request timed out. Check its status before retrying.',
      );
    } on http.ClientException {
      throw const BackendException(
        'Cannot reach the service. Check its URL and connection.',
      );
    }
  }

  void close() {
    _closed = true;
    _client.close();
  }
}
