import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ultimate_manga_tools/main.dart';
import 'package:ultimate_manga_tools/models.dart';

MangaProject sampleProject() {
  final bytes = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
  );
  return MangaProject(
    title: 'Chapter 01',
    pages: [
      MangaPage(
        id: '1',
        sourceName: 'page_01.png',
        originalBytes: bytes,
        originalMimeType: 'image/png',
      ),
    ],
  );
}

void setViewport(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Finder editorScrollable() =>
    find
        .descendant(
          of: find.byKey(const ValueKey('translation-editor-scroll')),
          matching: find.byType(Scrollable),
        )
        .first;

void main() {
  for (final size in [const Size(390, 844), const Size(1440, 900)]) {
    testWidgets('Import workspace fits ${size.width.toInt()}px viewport', (
      tester,
    ) async {
      setViewport(tester, size);
      await tester.pumpWidget(const MangaToolsApp());
      await tester.pumpAndSettle();

      expect(find.text('Start with a chapter'), findsOneWidget);
      expect(find.text('Import chapter'), findsOneWidget);
      expect(find.text('Open project'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Page review workspace fits ${size.width.toInt()}px viewport', (
      tester,
    ) async {
      setViewport(tester, size);
      await tester.pumpWidget(MangaToolsApp(initialProject: sampleProject()));
      await tester.pumpAndSettle();

      expect(find.text('page_01.png'), findsOneWidget);
      expect(find.text('Source'), findsOneWidget);
      expect(tester.takeException(), isNull);

      if (size.width < 760) {
        await tester.tap(find.text('Translate'));
        await tester.pumpAndSettle();
      }
      expect(find.text('Translate the page'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('inpaint-page')),
        250,
        scrollable: editorScrollable(),
      );
      await tester.pumpAndSettle();
      expect(find.text('Inpaint this page'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Export remains gated until an original is explicitly kept', (
    tester,
  ) async {
    setViewport(tester, const Size(1440, 900));
    final project = sampleProject();
    await tester.pumpWidget(MangaToolsApp(initialProject: project));
    await tester.pumpAndSettle();

    final export = find.widgetWithText(FilledButton, 'Export CBZ');
    expect(tester.widget<FilledButton>(export).onPressed, isNull);
    final keepOriginal = find.byKey(const ValueKey('keep-original-page'));
    await tester.scrollUntilVisible(
      keepOriginal,
      250,
      scrollable: editorScrollable(),
    );
    await tester.pumpAndSettle();
    await tester.tap(keepOriginal);
    await tester.pumpAndSettle();

    expect(project.pages.single.keepOriginal, isTrue);
    expect(tester.widget<FilledButton>(export).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Invalid remote HTTP service produces a recoverable validation error',
    (tester) async {
      setViewport(tester, const Size(1440, 900));
      await tester.pumpWidget(const MangaToolsApp());
      await tester.tap(find.text('Connect service'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField).first,
        'http://example.com:8787',
      );
      await tester.tap(find.text('Test connection'));
      await tester.pumpAndSettle();

      expect(
        find.text('Use HTTPS, or HTTP on localhost for development.'),
        findsOneWidget,
      );
      expect(find.text('Testing…'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
