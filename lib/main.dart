import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'models.dart';
import 'services/archive_service.dart';
import 'services/backend_client.dart';

const _ink = Color(0xFF24283D);
const _muted = Color(0xFF737684);
const _paper = Color(0xFFF6F4EF);
const _line = Color(0xFFE5E3DE);
const _indigo = Color(0xFF5250B8);
const _green = Color(0xFF397961);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MangaToolsApp());
}

class MangaToolsApp extends StatelessWidget {
  const MangaToolsApp({super.key, this.initialProject});
  final MangaProject? initialProject;

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: _indigo,
      brightness: Brightness.light,
      surface: _paper,
    );
    return MaterialApp(
      title: 'Ultimate Manga Tools',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        scaffoldBackgroundColor: _paper,
        textTheme: ThemeData.light().textTheme.apply(
          bodyColor: _ink,
          displayColor: _ink,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: _paper,
          foregroundColor: _ink,
          elevation: 0,
          scrolledUnderElevation: 0,
        ),
        dividerColor: _line,
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          isDense: true,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: _line),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: _line),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: _indigo,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: _ink,
            side: const BorderSide(color: _line),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        ),
        cardTheme: const CardThemeData(elevation: 0, color: Colors.white),
        tooltipTheme: const TooltipThemeData(
          waitDuration: Duration(milliseconds: 400),
        ),
      ),
      home: MangaWorkspace(initialProject: initialProject),
    );
  }
}

enum _PreviewMode { source, edited, compare }

class MangaWorkspace extends StatefulWidget {
  const MangaWorkspace({super.key, this.initialProject});
  final MangaProject? initialProject;

  @override
  State<MangaWorkspace> createState() => _MangaWorkspaceState();
}

class _MangaWorkspaceState extends State<MangaWorkspace> {
  final _archive = ArchiveService();
  final _transcript = TextEditingController();
  final _zoom = TransformationController();
  MangaProject? _project;
  int _selected = 0;
  int _mobileTab = 1;
  _PreviewMode _preview = _PreviewMode.source;
  String _serviceUrl = '';
  String _serviceToken = '';
  bool _serviceHealthy = false;
  bool _busy = false;
  bool _cancelRequested = false;
  bool _dirty = false;
  String _activity = '';
  String? _error;
  int _batchCompleted = 0;
  int _batchTotal = 0;
  BackendClient? _activeClient;

  MangaPage? get _page => _project == null ? null : _project!.pages[_selected];
  int get _approved =>
      _project?.pages.where((page) => page.exportReady).length ?? 0;
  bool get _connected => _serviceUrl.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    final project = widget.initialProject;
    if (project != null && project.pages.isNotEmpty) {
      _project = project;
      _transcript.text = project.pages.first.transcript;
      _preview =
          project.pages.first.editedBytes == null ||
                  project.pages.first.keepOriginal
              ? _PreviewMode.source
              : _PreviewMode.edited;
    }
  }

  @override
  void dispose() {
    _activeClient?.close();
    _transcript.dispose();
    _zoom.dispose();
    super.dispose();
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  String _friendlyError(Object error) {
    var message = error.toString();
    for (final prefix in [
      'Exception: ',
      'FormatException: ',
      'StateError: ',
      'Bad state: ',
    ]) {
      if (message.startsWith(prefix))
        message = message.substring(prefix.length);
    }
    // The token never belongs in an error surface, even if a remote service echoes it.
    if (_serviceToken.isNotEmpty)
      message = message.replaceAll(_serviceToken, '[hidden]');
    return message;
  }

  void _selectPage(int index) {
    if (_busy ||
        _project == null ||
        index < 0 ||
        index >= _project!.pages.length)
      return;
    setState(() {
      _selected = index;
      _transcript.text = _page!.transcript;
      _preview =
          _page!.editedBytes == null || _page!.keepOriginal
              ? _PreviewMode.source
              : _PreviewMode.edited;
      _zoom.value = Matrix4.identity();
      _mobileTab = 1;
    });
  }

  Future<bool> _confirmReplace() async {
    if (!_dirty) return true;
    return await showDialog<bool>(
          context: context,
          builder:
              (context) => AlertDialog(
                title: const Text('Replace this project?'),
                content: const Text(
                  'Your latest changes have not been saved. Save a project checkpoint first if you want to return to them.',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Go back'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Replace project'),
                  ),
                ],
              ),
        ) ??
        false;
  }

  Future<void> _open({bool checkpoint = false}) async {
    if (_busy || !await _confirmReplace() || !mounted) return;
    try {
      final picked = await FilePicker.platform.pickFiles(
        dialogTitle:
            checkpoint
                ? 'Open a Manga Tools project'
                : 'Import a manga archive',
        type: FileType.custom,
        allowedExtensions: checkpoint ? ['umt'] : ['cbz', 'zip'],
        withData: false,
        withReadStream: true,
      );
      if (picked == null || !mounted) return;
      final file = picked.files.single;
      setState(() {
        _busy = true;
        _activity = checkpoint ? 'Opening project…' : 'Reading archive…';
        _error = null;
      });
      // Yield a frame before archive validation and decoding.
      await Future<void>.delayed(Duration.zero);
      final bytes = await _readPickedFile(file, maxBytes: 256 * 1024 * 1024);
      final project =
          checkpoint
              ? _archive.openProject(bytes)
              : _archive.importCbz(
                bytes,
                title: file.name.replaceFirst(
                  RegExp(r'\.(cbz|zip)$', caseSensitive: false),
                  '',
                ),
              );
      if (!mounted) return;
      setState(() {
        _project = project;
        _selected = 0;
        _transcript.text = project.pages.first.transcript;
        _preview =
            project.pages.first.editedBytes == null ||
                    project.pages.first.keepOriginal
                ? _PreviewMode.source
                : _PreviewMode.edited;
        _zoom.value = Matrix4.identity();
        _dirty = !checkpoint;
        _mobileTab = 1;
      });
      _showMessage(
        '${project.pages.length} pages ${checkpoint ? 'restored' : 'imported in natural filename order'}.',
      );
    } catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    } finally {
      if (mounted)
        setState(() {
          _busy = false;
          _activity = '';
        });
    }
  }

  Future<Uint8List> _readPickedFile(
    PlatformFile file, {
    required int maxBytes,
  }) async {
    if (file.size > maxBytes)
      throw FormatException(
        'This file exceeds the ${maxBytes ~/ (1024 * 1024)} MB limit.',
      );
    final existing = file.bytes;
    if (existing != null) {
      if (existing.length > maxBytes)
        throw const FormatException('The file is too large.');
      return existing;
    }
    final stream =
        file.readStream ??
        (!kIsWeb && file.path != null ? File(file.path!).openRead() : null);
    if (stream == null)
      throw const FormatException(
        'Could not read that file. Copy it to this device and try again.',
      );
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      if (builder.length + chunk.length > maxBytes)
        throw const FormatException('The file is too large.');
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  Future<bool> _saveBytes(
    Uint8List bytes,
    String filename,
    String extension,
  ) async {
    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Save $filename',
      fileName: filename,
      type: FileType.custom,
      allowedExtensions: [extension],
      bytes: bytes,
    );
    if (path == null) return false;
    if (!kIsWeb && !Platform.isAndroid && !Platform.isIOS) {
      await File(path).writeAsBytes(bytes, flush: true);
    }
    return true;
  }

  String get _safeTitle {
    final name =
        (_project?.title ?? 'Manga')
            .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_')
            .trim();
    return name.isEmpty ? 'Manga' : name;
  }

  Future<void> _saveProject() async {
    if (_project == null || _busy) return;
    try {
      setState(() {
        _busy = true;
        _activity = 'Saving project…';
        _error = null;
      });
      final saved = await _saveBytes(
        _archive.saveProject(_project!),
        '$_safeTitle.umt',
        'umt',
      );
      if (saved && mounted) {
        setState(() => _dirty = false);
        _showMessage('Project saved. The service token is not included.');
      }
    } catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    } finally {
      if (mounted)
        setState(() {
          _busy = false;
          _activity = '';
        });
    }
  }

  Future<void> _export() async {
    if (_project == null || _busy || !_project!.exportReady) return;
    try {
      setState(() {
        _busy = true;
        _activity = 'Packaging CBZ…';
        _error = null;
      });
      final saved = await _saveBytes(
        _archive.exportCbz(_project!),
        '${_safeTitle}_English.cbz',
        'cbz',
      );
      if (saved)
        _showMessage(
          'CBZ exported with all ${_project!.pages.length} pages in order.',
        );
    } catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    } finally {
      if (mounted)
        setState(() {
          _busy = false;
          _activity = '';
        });
    }
  }

  Future<void> _importEdited() async {
    final page = _page;
    if (page == null || _busy) return;
    setState(() {
      _busy = true;
      _activity = 'Opening edited page…';
      _error = null;
    });
    try {
      final picked = await FilePicker.platform.pickFiles(
        dialogTitle: 'Import the edited version of ${page.sourceName}',
        type: FileType.custom,
        allowedExtensions: ['png', 'jpg', 'jpeg', 'webp'],
        withData: false,
        withReadStream: true,
      );
      if (picked == null || !mounted) return;
      final file = picked.files.single;
      final bytes = await _readPickedFile(file, maxBytes: 30 * 1024 * 1024);
      final mime = imageMimeType(bytes);
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      frame.image.dispose();
      codec.dispose();
      if (!mounted) return;
      setState(() {
        page.setEdited(bytes, mime, notes: 'Manually imported edited page.');
        _preview = _PreviewMode.edited;
        _dirty = true;
        _error = null;
        _zoom.value = Matrix4.identity();
      });
      _showMessage('Edited page imported. Inspect it before approving.');
    } catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    } finally {
      if (mounted)
        setState(() {
          _busy = false;
          _activity = '';
        });
    }
  }

  Future<void> _runPage({required bool inpaint}) async {
    final page = _page;
    final project = _project;
    if (page == null || project == null || _busy) return;
    if (!_connected) {
      await _settings();
      return;
    }
    final client = BackendClient(baseUrl: _serviceUrl, token: _serviceToken);
    _activeClient = client;
    setState(() {
      _busy = true;
      _cancelRequested = false;
      _activity =
          '${inpaint ? 'Inpainting' : 'Transcribing'} page ${_selected + 1}…';
      _error = null;
      _batchTotal = 0;
    });
    try {
      if (inpaint) {
        final result = await client.inpaint(page, project);
        if (!mounted || _cancelRequested) return;
        setState(() {
          page.setEdited(result.bytes, result.mimeType, notes: result.notes);
          _preview = _PreviewMode.edited;
          _dirty = true;
          _zoom.value = Matrix4.identity();
        });
        _showMessage(
          'Inpainting complete. Compare the artwork and lettering, then approve.',
        );
      } else {
        final text = await client.transcribe(page, project);
        if (!mounted || _cancelRequested) return;
        setState(() {
          page.setTranscript(text);
          _transcript.text = text;
          _dirty = true;
        });
        _showMessage(
          'Transcript ready. Check the English text before inpainting.',
        );
      }
    } catch (error) {
      if (mounted && !_cancelRequested)
        setState(() => _error = _friendlyError(error));
    } finally {
      client.close();
      _activeClient = null;
      if (mounted)
        setState(() {
          _busy = false;
          _activity = '';
        });
    }
  }

  Future<void> _batchTranscribe() async {
    final project = _project;
    if (project == null || _busy) return;
    if (!_connected) {
      await _settings();
      return;
    }
    final pending =
        project.pages
            .where(
              (page) => !page.exportReady && page.transcript.trim().isEmpty,
            )
            .toList();
    if (pending.isEmpty) {
      _showMessage(
        'Every pending page already has a transcript. Review one to continue.',
      );
      return;
    }
    final client = BackendClient(baseUrl: _serviceUrl, token: _serviceToken);
    _activeClient = client;
    setState(() {
      _busy = true;
      _cancelRequested = false;
      _batchTotal = pending.length;
      _batchCompleted = 0;
      _error = null;
    });
    try {
      for (final page in pending) {
        if (_cancelRequested || !mounted) break;
        setState(
          () =>
              _activity =
                  'Transcribing page ${project.pages.indexOf(page) + 1} of ${project.pages.length}…',
        );
        final text = await client.transcribe(page, project);
        if (_cancelRequested || !mounted) break;
        setState(() {
          page.setTranscript(text);
          if (page == _page) _transcript.text = text;
          _batchCompleted++;
          _dirty = true;
        });
      }
      if (!_cancelRequested)
        _showMessage(
          '$_batchCompleted transcripts ready. Review the text on each page before inpainting.',
        );
    } catch (error) {
      if (mounted && !_cancelRequested)
        setState(() => _error = _friendlyError(error));
    } finally {
      client.close();
      _activeClient = null;
      if (mounted)
        setState(() {
          _busy = false;
          _activity = '';
          _batchTotal = 0;
        });
    }
  }

  void _cancel() {
    _cancelRequested = true;
    _activeClient?.close();
    setState(() => _activity = 'Stopping…');
    _showMessage(
      'Stopping requests. Completed work is retained; a service request may still finish remotely.',
    );
  }

  Future<void> _settings() async {
    if (_busy) return;
    final result = await showDialog<_ServiceSettings>(
      context: context,
      builder:
          (context) => _SettingsDialog(url: _serviceUrl, token: _serviceToken),
    );
    if (result != null && mounted) {
      setState(() {
        _serviceUrl = result.url;
        _serviceToken = result.token;
        _serviceHealthy = result.healthy;
      });
    }
  }

  Future<void> _projectSettings() async {
    if (_project == null || _busy) return;
    final project = _project!;
    final title = TextEditingController(text: project.title);
    final glossary = TextEditingController(text: project.glossary);
    final saved = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('Chapter details'),
            content: SizedBox(
              width: 520,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: title,
                      decoration: const InputDecoration(
                        labelText: 'Chapter title',
                      ),
                    ),
                    const SizedBox(height: 20),
                    const Row(
                      children: [
                        Icon(Icons.translate_rounded, size: 19, color: _indigo),
                        SizedBox(width: 8),
                        Text('Japanese → English'),
                      ],
                    ),
                    const SizedBox(height: 20),
                    TextField(
                      controller: glossary,
                      maxLines: 8,
                      decoration: const InputDecoration(
                        labelText: 'Names & glossary',
                        alignLabelWithHint: true,
                        hintText:
                            'One term per line, for example:\n影山 = Kageyama\nKeep honorifics such as -san and -kun.',
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'The glossary accompanies new translation and inpainting requests. Existing pages are unchanged.',
                      style: TextStyle(
                        fontSize: 12,
                        color: _muted,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Save details'),
              ),
            ],
          ),
    );
    if (saved == true && mounted) {
      setState(() {
        project.title =
            title.text.trim().isEmpty ? project.title : title.text.trim();
        project.glossary = glossary.text;
        _dirty = true;
      });
    }
    // Dialog animations may still refer to these controllers until the next frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      title.dispose();
      glossary.dispose();
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 1180;
        final compact = constraints.maxWidth < 760;
        return Scaffold(
          appBar: _appBar(!wide),
          body: Column(
            children: [
              if (_error != null) _errorBanner(),
              if (_busy) _activityBar(),
              Expanded(
                child:
                    _project == null
                        ? _emptyState(compact)
                        : _workspace(wide: wide, compact: compact),
              ),
              if (!compact) _footer(),
            ],
          ),
          bottomNavigationBar:
              compact && _project != null
                  ? NavigationBar(
                    selectedIndex: _mobileTab,
                    onDestinationSelected:
                        (index) => setState(() => _mobileTab = index),
                    destinations: const [
                      NavigationDestination(
                        icon: Icon(Icons.view_list_outlined),
                        selectedIcon: Icon(Icons.view_list_rounded),
                        label: 'Pages',
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.auto_stories_outlined),
                        selectedIcon: Icon(Icons.auto_stories_rounded),
                        label: 'Preview',
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.edit_note_rounded),
                        label: 'Translate',
                      ),
                    ],
                  )
                  : null,
        );
      },
    );
  }

  PreferredSizeWidget _appBar(bool compact) {
    return AppBar(
      toolbarHeight: compact ? 64 : 80,
      automaticallyImplyLeading: false,
      titleSpacing: compact ? 16 : 26,
      title: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: _ink,
              borderRadius: BorderRadius.circular(11),
            ),
            child: const Icon(
              Icons.auto_stories_rounded,
              size: 21,
              color: Colors.white,
            ),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                compact ? 'Manga Tools' : 'Ultimate Manga Tools',
                style: TextStyle(
                  fontSize: compact ? 16 : 19,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -.4,
                ),
              ),
              if (!compact)
                const Text(
                  'A careful translation workspace',
                  style: TextStyle(
                    fontSize: 11,
                    color: _muted,
                    letterSpacing: .3,
                  ),
                ),
            ],
          ),
        ],
      ),
      actions: [
        if (!compact) ...[
          TextButton.icon(
            onPressed: _busy ? null : _settings,
            icon: Icon(
              _serviceHealthy
                  ? Icons.check_circle_outline_rounded
                  : Icons.circle_outlined,
              size: 16,
              color: _serviceHealthy ? _green : _muted,
            ),
            label: Text(
              _serviceHealthy
                  ? 'Service connected'
                  : _connected
                  ? 'Service configured'
                  : 'Connect service',
            ),
          ),
          const SizedBox(width: 10),
          if (_project != null)
            OutlinedButton.icon(
              onPressed: _busy ? null : _saveProject,
              icon: const Icon(Icons.save_outlined, size: 18),
              label: Text(_dirty ? 'Save project •' : 'Save project'),
            ),
          const SizedBox(width: 10),
          if (_project != null)
            Tooltip(
              message:
                  _project!.exportReady
                      ? 'Export all approved pages as CBZ'
                      : 'Approve or explicitly keep each original before export',
              child: FilledButton.icon(
                onPressed: _busy || !_project!.exportReady ? null : _export,
                icon: const Icon(Icons.file_download_outlined, size: 18),
                label: const Text('Export CBZ'),
              ),
            ),
          const SizedBox(width: 12),
        ],
        PopupMenuButton<String>(
          tooltip: 'Workspace actions',
          enabled: !_busy,
          onSelected: (value) {
            switch (value) {
              case 'import':
                _open();
              case 'open':
                _open(checkpoint: true);
              case 'save':
                _saveProject();
              case 'export':
                _export();
              case 'details':
                _projectSettings();
              case 'settings':
                _settings();
            }
          },
          itemBuilder:
              (context) => [
                const PopupMenuItem(
                  value: 'import',
                  child: Text('Import ZIP / CBZ'),
                ),
                const PopupMenuItem(
                  value: 'open',
                  child: Text('Open saved project'),
                ),
                if (_project != null) ...[
                  const PopupMenuItem(
                    value: 'save',
                    child: Text('Save project'),
                  ),
                  PopupMenuItem(
                    value: 'export',
                    enabled: _project!.exportReady,
                    child: const Text('Export CBZ'),
                  ),
                  const PopupMenuItem(
                    value: 'details',
                    child: Text('Chapter details & glossary'),
                  ),
                ],
                const PopupMenuItem(
                  value: 'settings',
                  child: Text('Service connection'),
                ),
              ],
        ),
        SizedBox(width: compact ? 6 : 14),
      ],
      bottom: const PreferredSize(
        preferredSize: Size.fromHeight(1),
        child: Divider(height: 1),
      ),
    );
  }

  Widget _emptyState(bool compact) {
    return Center(
      child: SingleChildScrollView(
        padding: EdgeInsets.all(compact ? 24 : 48),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 860),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const _Eyebrow('FROM ORIGINAL TO ENGLISH'),
              const SizedBox(height: 18),
              Text(
                'Your next chapter,\nin your own words.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: compact ? 34 : 48,
                  fontWeight: FontWeight.w700,
                  height: 1.1,
                  letterSpacing: -1.8,
                ),
              ),
              const SizedBox(height: 20),
              const ConstrainedBox(
                constraints: BoxConstraints(maxWidth: 580),
                child: Text(
                  'Translate the dialogue. Restore the artwork. Review every page. A focused workspace for English-lettered manga archives.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 16, color: _muted, height: 1.6),
                ),
              ),
              const SizedBox(height: 32),
              Container(
                width: double.infinity,
                padding: EdgeInsets.all(compact ? 24 : 38),
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: _line),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Column(
                  children: [
                    Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        color: _indigo.withValues(alpha: .08),
                        borderRadius: BorderRadius.circular(17),
                      ),
                      child: const Icon(
                        Icons.library_add_outlined,
                        size: 30,
                        color: _indigo,
                      ),
                    ),
                    const SizedBox(height: 20),
                    const Text(
                      'Start with a chapter',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -.5,
                      ),
                    ),
                    const SizedBox(height: 9),
                    const Text(
                      'Import a ZIP or CBZ containing page images.\nPages are sorted by their original filenames.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: _muted, height: 1.6),
                    ),
                    const SizedBox(height: 24),
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        FilledButton.icon(
                          onPressed: _busy ? null : () => _open(),
                          icon: const Icon(Icons.add_rounded, size: 20),
                          label: const Text('Import chapter'),
                        ),
                        OutlinedButton.icon(
                          onPressed:
                              _busy ? null : () => _open(checkpoint: true),
                          icon: const Icon(Icons.folder_open_rounded, size: 19),
                          label: const Text('Open project'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 28),
              if (compact)
                const Column(
                  children: [
                    _WorkflowStep(
                      number: '01',
                      title: 'Read & translate',
                      body: 'Create a transcript and refine the English.',
                    ),
                    SizedBox(height: 18),
                    _WorkflowStep(
                      number: '02',
                      title: 'Inpaint & inspect',
                      body: 'Compare the edited page with its source.',
                    ),
                    SizedBox(height: 18),
                    _WorkflowStep(
                      number: '03',
                      title: 'Approve & export',
                      body: 'Package your reviewed pages into a CBZ.',
                    ),
                  ],
                )
              else
                const Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: _WorkflowStep(
                        number: '01',
                        title: 'Read & translate',
                        body: 'Create a transcript and refine the English.',
                      ),
                    ),
                    SizedBox(width: 24),
                    Expanded(
                      child: _WorkflowStep(
                        number: '02',
                        title: 'Inpaint & inspect',
                        body: 'Compare the edited page with its source.',
                      ),
                    ),
                    SizedBox(width: 24),
                    Expanded(
                      child: _WorkflowStep(
                        number: '03',
                        title: 'Approve & export',
                        body: 'Package your reviewed pages into a CBZ.',
                      ),
                    ),
                  ],
                ),
              const SizedBox(height: 32),
              const Text(
                'AI translation and inpainting require your configured service.\nYou can also import edited pages and export without AI.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: _muted, height: 1.6),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _workspace({required bool wide, required bool compact}) {
    if (compact) {
      return switch (_mobileTab) {
        0 => _pageRail(),
        2 => _editPanel(),
        _ => _previewPanel(compact: true),
      };
    }
    return Row(
      children: [
        SizedBox(width: wide ? 238 : 196, child: _pageRail()),
        const VerticalDivider(width: 1),
        Expanded(
          child:
              wide
                  ? _previewPanel()
                  : Column(
                    children: [
                      Expanded(
                        child: _mobileTab == 2 ? _editPanel() : _previewPanel(),
                      ),
                      Container(
                        height: 58,
                        decoration: const BoxDecoration(
                          color: Colors.white,
                          border: Border(top: BorderSide(color: _line)),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 18),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                _page!.exportReady
                                    ? 'Page approved'
                                    : 'Ready to translate and review',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: _muted,
                                ),
                              ),
                            ),
                            TextButton.icon(
                              onPressed:
                                  () => setState(
                                    () => _mobileTab = _mobileTab == 2 ? 1 : 2,
                                  ),
                              icon: Icon(
                                _mobileTab == 2
                                    ? Icons.auto_stories_outlined
                                    : Icons.edit_note_rounded,
                              ),
                              label: Text(
                                _mobileTab == 2
                                    ? 'Back to preview'
                                    : 'Open editor',
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
        ),
        if (wide) ...[
          const VerticalDivider(width: 1),
          SizedBox(width: 350, child: _editPanel()),
        ],
      ],
    );
  }

  Widget _pageRail() {
    final project = _project!;
    return ColoredBox(
      color: const Color(0xFFFBFAF7),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 23, 16, 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(child: _Eyebrow('CHAPTER WORKSPACE')),
                    IconButton(
                      tooltip: 'Chapter details & glossary',
                      onPressed: _busy ? null : _projectSettings,
                      icon: const Icon(Icons.tune_rounded, size: 18),
                      visualDensity: VisualDensity.compact,
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  project.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 15),
                Row(
                  children: [
                    Text(
                      '$_approved / ${project.pages.length} approved',
                      style: const TextStyle(fontSize: 12, color: _muted),
                    ),
                    const Spacer(),
                    const Icon(
                      Icons.translate_rounded,
                      size: 14,
                      color: _muted,
                    ),
                    const SizedBox(width: 4),
                    const Text(
                      'EN',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: _muted,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 9),
                ClipRRect(
                  borderRadius: BorderRadius.circular(5),
                  child: LinearProgressIndicator(
                    value: _approved / project.pages.length,
                    backgroundColor: _line,
                    color: _green,
                    minHeight: 4,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              itemCount: project.pages.length,
              separatorBuilder: (context, index) => const SizedBox(height: 6),
              itemBuilder: (context, index) {
                final page = project.pages[index];
                final selected = index == _selected;
                final status =
                    page.exportReady
                        ? (page.keepOriginal ? 'Original kept' : 'Approved')
                        : page.editedBytes != null
                        ? 'Needs review'
                        : page.transcript.trim().isNotEmpty
                        ? 'Transcript ready'
                        : 'Not started';
                return Material(
                  color:
                      selected
                          ? _indigo.withValues(alpha: .08)
                          : Colors.transparent,
                  borderRadius: BorderRadius.circular(10),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: _busy ? null : () => _selectPage(index),
                    child: Padding(
                      padding: const EdgeInsets.all(9),
                      child: Row(
                        children: [
                          Container(
                            width: 42,
                            height: 56,
                            clipBehavior: Clip.antiAlias,
                            decoration: BoxDecoration(
                              color: Colors.white,
                              border: Border.all(
                                color:
                                    selected
                                        ? _indigo.withValues(alpha: .35)
                                        : _line,
                              ),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Image.memory(
                              page.keepOriginal
                                  ? page.originalBytes
                                  : page.displayBytes,
                              fit: BoxFit.cover,
                              cacheWidth: 110,
                              gaplessPlayback: true,
                              errorBuilder:
                                  (context, error, stackTrace) => const Icon(
                                    Icons.image_not_supported_outlined,
                                    size: 19,
                                    color: _muted,
                                  ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Page ${(index + 1).toString().padLeft(2, '0')}',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight:
                                        selected
                                            ? FontWeight.w700
                                            : FontWeight.w600,
                                    color: selected ? _indigo : _ink,
                                  ),
                                ),
                                const SizedBox(height: 5),
                                Text(
                                  status,
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: page.exportReady ? _green : _muted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (page.exportReady)
                            const Icon(
                              Icons.check_circle_rounded,
                              color: _green,
                              size: 16,
                            ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(14),
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _busy ? null : _batchTranscribe,
                icon: const Icon(Icons.playlist_play_rounded, size: 19),
                label: const Text(
                  'Transcribe pending',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _previewPanel({bool compact = false}) {
    final page = _page!;
    final hasEdited = page.editedBytes != null;
    return Column(
      children: [
        Container(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 14 : 24,
            vertical: 16,
          ),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: _line)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Page ${(_selected + 1).toString().padLeft(2, '0')}',
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -.5,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          page.sourceName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: _muted, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Previous page',
                    onPressed:
                        _busy || _selected == 0
                            ? null
                            : () => _selectPage(_selected - 1),
                    icon: const Icon(Icons.chevron_left_rounded),
                  ),
                  Text(
                    '${_selected + 1} / ${_project!.pages.length}',
                    style: const TextStyle(fontSize: 11, color: _muted),
                  ),
                  IconButton(
                    tooltip: 'Next page',
                    onPressed:
                        _busy || _selected == _project!.pages.length - 1
                            ? null
                            : () => _selectPage(_selected + 1),
                    icon: const Icon(Icons.chevron_right_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: SegmentedButton<_PreviewMode>(
                        showSelectedIcon: false,
                        style: SegmentedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          textStyle: const TextStyle(fontSize: 12),
                          selectedBackgroundColor: Colors.white,
                          selectedForegroundColor: _indigo,
                          side: const BorderSide(color: _line),
                        ),
                        segments: [
                          const ButtonSegment(
                            value: _PreviewMode.source,
                            label: Text('Source'),
                            icon: Icon(Icons.image_outlined, size: 15),
                          ),
                          ButtonSegment(
                            value: _PreviewMode.edited,
                            label: const Text('Edited'),
                            icon: const Icon(
                              Icons.auto_fix_high_rounded,
                              size: 15,
                            ),
                            enabled: hasEdited,
                          ),
                          ButtonSegment(
                            value: _PreviewMode.compare,
                            label: const Text('Compare'),
                            icon: const Icon(Icons.compare_rounded, size: 15),
                            enabled: hasEdited,
                          ),
                        ],
                        selected: {_preview},
                        onSelectionChanged:
                            (value) => setState(() {
                              _preview = value.first;
                              _zoom.value = Matrix4.identity();
                            }),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Reset zoom',
                    onPressed: () => _zoom.value = Matrix4.identity(),
                    icon: const Icon(Icons.fit_screen_rounded, size: 20),
                  ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: Container(
            color: const Color(0xFFEAE9E5),
            width: double.infinity,
            child: InteractiveViewer(
              transformationController: _zoom,
              minScale: .5,
              maxScale: 8,
              boundaryMargin: const EdgeInsets.all(120),
              child: Padding(
                padding: EdgeInsets.all(compact ? 14 : 28),
                child:
                    _preview == _PreviewMode.compare && hasEdited
                        ? Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              child: _pageImage(page.originalBytes, 'SOURCE'),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: _pageImage(page.editedBytes!, 'EDITED'),
                            ),
                          ],
                        )
                        : _pageImage(
                          _preview == _PreviewMode.source
                              ? page.originalBytes
                              : page.editedBytes ?? page.originalBytes,
                          null,
                        ),
              ),
            ),
          ),
        ),
        Container(
          height: 42,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            children: [
              const Icon(Icons.pinch_rounded, size: 14, color: _muted),
              const SizedBox(width: 7),
              const Expanded(
                child: Text(
                  'Pinch or scroll to zoom · drag to pan',
                  style: TextStyle(fontSize: 10, color: _muted),
                ),
              ),
              if (page.exportReady)
                const _StatusPill(label: 'APPROVED', color: _green),
              if (!page.exportReady && page.editedBytes != null)
                const _StatusPill(
                  label: 'REVIEW NEEDED',
                  color: Color(0xFF9D6A26),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _pageImage(Uint8List bytes, String? label) {
    return Column(
      children: [
        if (label != null) ...[
          Text(
            label,
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: _muted,
              letterSpacing: 1.3,
            ),
          ),
          const SizedBox(height: 10),
        ],
        Expanded(
          child: Center(
            child: Image.memory(
              bytes,
              fit: BoxFit.contain,
              gaplessPlayback: true,
              errorBuilder:
                  (context, error, stackTrace) => const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.broken_image_outlined,
                        color: _muted,
                        size: 32,
                      ),
                      SizedBox(height: 8),
                      Text(
                        'This image cannot be displayed.',
                        style: TextStyle(color: _muted),
                      ),
                    ],
                  ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _editPanel() {
    final page = _page!;
    final readyForInpaint = page.transcript.trim().isNotEmpty;
    return ColoredBox(
      color: const Color(0xFFFBFAF7),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(22, 24, 22, 28),
        children: [
          Row(
            children: [
              const Expanded(child: _Eyebrow('TRANSLATION STUDIO')),
              TextButton(
                onPressed: _busy ? null : _projectSettings,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                child: const Text('Glossary', style: TextStyle(fontSize: 11)),
              ),
            ],
          ),
          const SizedBox(height: 20),
          const _SectionTitle(number: '1', title: 'Translate the page'),
          const SizedBox(height: 10),
          const Text(
            'Read the source and create an English transcript in reading order.',
            style: TextStyle(fontSize: 12, color: _muted, height: 1.6),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _busy ? null : () => _runPage(inpaint: false),
              icon: const Icon(Icons.translate_rounded, size: 18),
              label: Text(
                page.transcript.isEmpty
                    ? 'Transcribe & translate'
                    : 'Transcribe again',
              ),
            ),
          ),
          const SizedBox(height: 17),
          const Text(
            'ENGLISH TRANSCRIPT',
            style: TextStyle(
              fontSize: 9,
              letterSpacing: 1.3,
              fontWeight: FontWeight.w700,
              color: _muted,
            ),
          ),
          const SizedBox(height: 9),
          TextField(
            controller: _transcript,
            enabled: !_busy,
            minLines: 7,
            maxLines: 16,
            style: const TextStyle(fontSize: 13, height: 1.65),
            decoration: const InputDecoration(
              hintText:
                  'Translated dialogue will appear here.\n\nYou can also type your own transcript. Identify bubbles and captions in reading order.',
              contentPadding: EdgeInsets.all(14),
            ),
            onChanged:
                (text) => setState(() {
                  page.setTranscript(text);
                  _dirty = true;
                }),
          ),
          const SizedBox(height: 9),
          const Text(
            'Check names, meaning and bubble order before continuing.',
            style: TextStyle(fontSize: 10, color: _muted, height: 1.5),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Divider(height: 1),
          ),
          const _SectionTitle(number: '2', title: 'Letter the artwork'),
          const SizedBox(height: 10),
          const Text(
            'Replace the source lettering using your edited transcript. The result needs a visual review.',
            style: TextStyle(fontSize: 12, color: _muted, height: 1.6),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed:
                  _busy || !readyForInpaint
                      ? null
                      : () => _runPage(inpaint: true),
              icon: const Icon(Icons.auto_fix_high_rounded, size: 18),
              label: Text(
                page.editedBytes == null
                    ? 'Inpaint this page'
                    : 'Inpaint again',
              ),
            ),
          ),
          const SizedBox(height: 5),
          TextButton.icon(
            onPressed: _busy ? null : _importEdited,
            icon: const Icon(Icons.upload_file_rounded, size: 17),
            label: const Text(
              'Import an edited page',
              style: TextStyle(fontSize: 12),
            ),
          ),
          if (page.notes.trim().isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFF0EDE4),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'PAGE NOTES',
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1,
                      color: _muted,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    page.notes,
                    style: const TextStyle(fontSize: 11, height: 1.6),
                  ),
                ],
              ),
            ),
          ],
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Divider(height: 1),
          ),
          const _SectionTitle(number: '3', title: 'Review & approve'),
          const SizedBox(height: 10),
          const Text(
            'Compare every panel. Check the English, artwork, page edges and any required omissions.',
            style: TextStyle(fontSize: 12, color: _muted, height: 1.6),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: _green),
              onPressed:
                  _busy ||
                          page.editedBytes == null ||
                          (page.reviewed && !page.keepOriginal)
                      ? null
                      : () => setState(() {
                        page.useOriginal(false);
                        page.markReviewed();
                        _dirty = true;
                      }),
              icon: Icon(
                page.reviewed && !page.keepOriginal
                    ? Icons.check_circle_rounded
                    : Icons.check_rounded,
                size: 18,
              ),
              label: Text(
                page.reviewed && !page.keepOriginal
                    ? 'Edited page approved'
                    : 'Approve edited page',
              ),
            ),
          ),
          const SizedBox(height: 6),
          CheckboxListTile(
            value: page.keepOriginal,
            onChanged:
                _busy
                    ? null
                    : (value) => setState(() {
                      page.useOriginal(value ?? false);
                      if (value == true) {
                        _preview = _PreviewMode.source;
                        _zoom.value = Matrix4.identity();
                      }
                      _dirty = true;
                    }),
            title: const Text(
              'Keep the original page',
              style: TextStyle(fontSize: 12),
            ),
            subtitle: const Text(
              'Include the source unchanged in the export.',
              style: TextStyle(fontSize: 10, color: _muted, height: 1.5),
            ),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            dense: true,
            visualDensity: VisualDensity.compact,
          ),
          const SizedBox(height: 22),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              border: Border.all(color: _line),
              borderRadius: BorderRadius.circular(9),
            ),
            child: const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline_rounded, size: 15, color: _muted),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'AI requests send this page, its transcript and the glossary to your configured service. Images may change. Review before export.',
                    style: TextStyle(fontSize: 10, color: _muted, height: 1.6),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _footer() {
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 26),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: _line)),
      ),
      child: Row(
        children: [
          const Icon(Icons.lock_outline_rounded, size: 12, color: _muted),
          const SizedBox(width: 7),
          const Text(
            'Files stay on this device until you request AI processing.',
            style: TextStyle(fontSize: 10, color: _muted),
          ),
          const Spacer(),
          Text(
            _project == null
                ? 'JAPANESE → ENGLISH'
                : _dirty
                ? 'Unsaved changes · save a project checkpoint'
                : 'Project checkpoint saved',
            style: const TextStyle(
              fontSize: 10,
              color: _muted,
              letterSpacing: .3,
            ),
          ),
        ],
      ),
    );
  }

  Widget _errorBanner() {
    return Material(
      color: const Color(0xFFFBEDE7),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 10, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const Icon(
              Icons.error_outline_rounded,
              color: Color(0xFF9F4433),
              size: 20,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _error!,
                style: const TextStyle(
                  color: Color(0xFF823B2E),
                  fontSize: 12,
                  height: 1.5,
                ),
              ),
            ),
            IconButton(
              tooltip: 'Dismiss error',
              onPressed: () => setState(() => _error = null),
              icon: const Icon(Icons.close_rounded, size: 18),
            ),
          ],
        ),
      ),
    );
  }

  Widget _activityBar() {
    return Column(
      children: [
        LinearProgressIndicator(
          value: _batchTotal > 0 ? _batchCompleted / _batchTotal : null,
          minHeight: 2,
          color: _indigo,
          backgroundColor: _indigo.withValues(alpha: .08),
        ),
        Container(
          height: 43,
          padding: const EdgeInsets.symmetric(horizontal: 22),
          color: _indigo.withValues(alpha: .05),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _activity,
                  style: const TextStyle(fontSize: 12, color: _indigo),
                ),
              ),
              if (_batchTotal > 0)
                Text(
                  '$_batchCompleted / $_batchTotal complete',
                  style: const TextStyle(fontSize: 10, color: _muted),
                ),
              if (_activeClient != null)
                TextButton(
                  onPressed: _cancelRequested ? null : _cancel,
                  child: const Text('Stop', style: TextStyle(fontSize: 12)),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ServiceSettings {
  const _ServiceSettings(this.url, this.token, this.healthy);
  final String url;
  final String token;
  final bool healthy;
}

class _SettingsDialog extends StatefulWidget {
  const _SettingsDialog({required this.url, required this.token});
  final String url;
  final String token;

  @override
  State<_SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<_SettingsDialog> {
  late final TextEditingController _url = TextEditingController(
    text: widget.url,
  );
  late final TextEditingController _token = TextEditingController(
    text: widget.token,
  );
  bool _testing = false;
  bool _healthy = false;
  String? _message;
  BackendClient? _client;

  @override
  void dispose() {
    _client?.close();
    _url.dispose();
    _token.dispose();
    super.dispose();
  }

  String? _validate() {
    try {
      BackendClient.validateBaseUrl(_url.text);
      return null;
    } on FormatException catch (error) {
      return error.message;
    }
  }

  Future<void> _test() async {
    final validation = _validate();
    if (validation != null) {
      setState(() {
        _message = validation;
        _healthy = false;
      });
      return;
    }
    setState(() {
      _testing = true;
      _message = null;
      _healthy = false;
    });
    final client = BackendClient(baseUrl: _url.text.trim(), token: _token.text);
    _client = client;
    try {
      await client.health();
      if (mounted)
        setState(() {
          _healthy = true;
          _message = 'Service is reachable and ready.';
        });
    } catch (error) {
      var message = error.toString().replaceFirst('Exception: ', '');
      if (_token.text.isNotEmpty)
        message = message.replaceAll(_token.text, '[hidden]');
      if (mounted) setState(() => _message = message);
    } finally {
      client.close();
      _client = null;
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Connect your AI service'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Run the companion service, then enter its address. Model provider credentials stay on the service; this app only uses its access token.',
                style: TextStyle(fontSize: 13, color: _muted, height: 1.6),
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _url,
                enabled: !_testing,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Service URL',
                  hintText: 'https://your-manga-service.example',
                ),
                onChanged:
                    (_) => setState(() {
                      _healthy = false;
                      _message = null;
                    }),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _token,
                enabled: !_testing,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  labelText: 'Service access token',
                  prefixIcon: Icon(Icons.key_rounded, size: 19),
                ),
                onChanged:
                    (_) => setState(() {
                      _healthy = false;
                      _message = null;
                    }),
              ),
              const SizedBox(height: 10),
              const Text(
                'Kept in memory for this session only. Never stored in project files.',
                style: TextStyle(fontSize: 11, color: _muted, height: 1.5),
              ),
              const SizedBox(height: 22),
              const Text(
                'When you request AI processing, page images, transcript text and your glossary are sent to this service and its model provider. Use a service you trust.',
                style: TextStyle(fontSize: 12, color: _muted, height: 1.6),
              ),
              if (_message != null) ...[
                const SizedBox(height: 18),
                Text(
                  _message!,
                  style: TextStyle(
                    fontSize: 12,
                    color: _healthy ? _green : const Color(0xFF9F4433),
                    height: 1.5,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _testing ? null : _test,
          child: Text(_testing ? 'Testing…' : 'Test connection'),
        ),
        TextButton(
          onPressed: _testing ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed:
              _testing
                  ? null
                  : () {
                    final validation = _validate();
                    if (validation != null) {
                      setState(() => _message = validation);
                      return;
                    }
                    Navigator.pop(
                      context,
                      _ServiceSettings(
                        _url.text.trim().replaceFirst(RegExp(r'/+$'), ''),
                        _token.text,
                        _healthy,
                      ),
                    );
                  },
          child: const Text('Save connection'),
        ),
      ],
    );
  }
}

class _Eyebrow extends StatelessWidget {
  const _Eyebrow(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: const TextStyle(
      fontSize: 9,
      letterSpacing: 1.5,
      fontWeight: FontWeight.w700,
      color: _muted,
    ),
  );
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.number, required this.title});
  final String number;
  final String title;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Container(
        width: 23,
        height: 23,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: _indigo.withValues(alpha: .08),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          number,
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: _indigo,
          ),
        ),
      ),
      const SizedBox(width: 9),
      Expanded(
        child: Text(
          title,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            letterSpacing: -.25,
          ),
        ),
      ),
    ],
  );
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .08),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(
      label,
      style: TextStyle(
        fontSize: 8,
        fontWeight: FontWeight.w700,
        letterSpacing: .6,
        color: color,
      ),
    ),
  );
}

class _WorkflowStep extends StatelessWidget {
  const _WorkflowStep({
    required this.number,
    required this.title,
    required this.body,
  });
  final String number;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        number,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: _indigo,
          height: 1.7,
        ),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 7),
            Text(
              body,
              style: const TextStyle(fontSize: 12, color: _muted, height: 1.6),
            ),
          ],
        ),
      ),
    ],
  );
}
