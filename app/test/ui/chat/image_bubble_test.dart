// Plan/30 — ImageBubble renders a static thumbnail from base64 + optional
// caption, with a broken-image fallback for bad data.

import 'dart:convert';

import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/widgets/image_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// 1×1 transparent PNG.
const _transparentPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';
const _redPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==';

void main() {
  Future<void> pump(
    WidgetTester tester,
    List<MessageImage> images,
    String caption,
  ) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: ImageBubble(images: images, caption: caption),
          ),
        ),
      ),
    );
  }

  testWidgets('renders every image in stable order and the caption', (
    tester,
  ) async {
    await pump(tester, const [
      MessageImage(data: _transparentPng, mime: 'image/png'),
      MessageImage(data: _redPng, mime: 'image/png'),
    ], 'a kitten');
    await tester.pump();
    expect(find.byType(Image), findsNWidgets(2));
    final rendered = tester.widgetList<Image>(find.byType(Image)).toList();
    expect(
      base64Encode((rendered.first.image as MemoryImage).bytes),
      _transparentPng,
    );
    expect(base64Encode((rendered.last.image as MemoryImage).bytes), _redPng);
    expect(find.byKey(const Key('message-image-0')), findsOneWidget);
    expect(find.byKey(const Key('message-image-1')), findsOneWidget);
    expect(find.text('a kitten'), findsOneWidget);
  });

  testWidgets('renders without a caption when empty', (tester) async {
    await pump(tester, const [
      MessageImage(data: _transparentPng, mime: 'image/jpeg'),
    ], '');
    await tester.pump();
    expect(find.byType(Image), findsOneWidget);
    expect(find.byType(Text), findsNothing);
  });

  testWidgets('falls back to a broken-image glyph on bad base64', (
    tester,
  ) async {
    await pump(tester, const [
      MessageImage(data: 'not valid base64 !!', mime: 'image/jpeg'),
    ], '');
    await tester.pump();
    expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });
}
