import 'dart:ui' show SemanticsAction;

import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/widgets/message_bubble.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pump(
    WidgetTester tester,
    CompactionMsg msg, {
    ThemeData? theme,
  }) {
    var expanded = false;
    return tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: SingleChildScrollView(
            child: StatefulBuilder(
              builder: (context, setState) => CompactionBubble(
                msg,
                expanded: expanded,
                onToggle: () => setState(() => expanded = !expanded),
              ),
            ),
          ),
        ),
      ),
    );
  }

  for (final brightness in Brightness.values) {
    testWidgets(
      'collapsed title/count and accessible toggle fit narrow large text ($brightness)',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(280, 700));
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(() {
          tester.platformDispatcher.clearTextScaleFactorTestValue();
          return tester.binding.setSurfaceSize(null);
        });
        final semantics = tester.ensureSemantics();
        try {
          await pump(
            tester,
            const CompactionMsg(
              id: 'c1',
              summary:
                  'Recapped the long thread\nKeeping the original details.',
              tokensBefore: 12000,
            ),
            theme: brightness == Brightness.dark
                ? buildDarkTheme()
                : buildLightTheme(),
          );
          const label = 'Context compacted, collapsed, ~12000 tokens';
          expect(find.text('Context compacted'), findsOneWidget);
          expect(find.text('~12000 tokens'), findsOneWidget);
          final summary = find.text(
            'Recapped the long thread\nKeeping the original details.',
          );
          expect(summary, findsNothing);
          final header = find.bySemanticsLabel(label);
          expect(
            tester.getSemantics(header),
            matchesSemantics(
              label: label,
              isButton: true,
              hasTapAction: true,
              hasExpandedState: true,
            ),
          );
          expect(tester.getSize(header).height, greaterThanOrEqualTo(48));
          expect(
            find.semantics.byPredicate(
              (node) => node.getSemanticsData().hasAction(SemanticsAction.tap),
            ),
            findsOneWidget,
          );
          final chevron = find.byIcon(Icons.expand_more);
          final cardRect = tester.getRect(find.byType(CompactionBubble));
          expect(cardRect.contains(tester.getTopLeft(chevron)), isTrue);
          expect(cardRect.contains(tester.getBottomRight(chevron)), isTrue);
          expect(tester.takeException(), isNull);
          tester.semantics.tap(find.semantics.byLabel(label));
          await tester.pump();
          expect(summary, findsOneWidget);
          expect(find.text('~12000 tokens'), findsOneWidget);
          expect(
            tester.getSemantics(
              find.bySemanticsLabel(
                'Context compacted, expanded, ~12000 tokens',
              ),
            ),
            matchesSemantics(
              label: 'Context compacted, expanded, ~12000 tokens',
              isButton: true,
              hasTapAction: true,
              hasExpandedState: true,
              isExpanded: true,
            ),
          );
          await tester.tap(find.byIcon(Icons.expand_less));
          await tester.pump();
          expect(summary, findsNothing);
          expect(header, findsOneWidget);
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      },
      variant: TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.iOS,
      }),
    );
  }

  testWidgets('missing token count still allows summary expansion', (
    tester,
  ) async {
    await pump(tester, const CompactionMsg(id: 'c2', summary: 'done'));
    expect(find.text('Context compacted'), findsOneWidget);
    expect(find.text('done'), findsNothing);
    expect(find.textContaining('tokens'), findsNothing);
    await tester.tap(find.text('Context compacted'));
    await tester.pump();
    expect(find.text('done'), findsOneWidget);
    expect(find.textContaining('tokens'), findsNothing);
  });

  testWidgets('empty summary has no expand affordance or action', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      for (final tokens in [null, 12000]) {
        await pump(
          tester,
          CompactionMsg(id: 'empty', summary: '', tokensBefore: tokens),
        );
        expect(find.text('Context compacted'), findsOneWidget);
        expect(
          find.text('~12000 tokens'),
          tokens == null ? findsNothing : findsOneWidget,
        );
        expect(find.byIcon(Icons.expand_more), findsNothing);
        expect(find.byIcon(Icons.expand_less), findsNothing);
        expect(
          find.semantics.byPredicate(
            (node) => node.getSemanticsData().hasAction(SemanticsAction.tap),
          ),
          findsNothing,
        );
      }
    } finally {
      semantics.dispose();
    }
  });
}
