import 'dart:ui' show SemanticsAction;

import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/widgets/tool_request_card.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(ToolEvent tool, {ThemeData? theme, VoidCallback? onDecide}) {
  var expanded = false;
  return MaterialApp(
    theme: theme,
    home: Scaffold(
      body: StatefulBuilder(
        builder: (context, setState) => ToolRequestCard(
          tool: tool,
          expanded: expanded,
          onToggle: () => setState(() => expanded = !expanded),
          onDecide: (_, _) => onDecide?.call(),
        ),
      ),
    ),
  );
}

Future<void> _toggle(WidgetTester tester) async {
  await tester.tap(find.text('BASH'));
  await tester.pump();
}

const _bashTool = ToolEvent(
  id: 'tc1',
  toolCallId: 'tc1',
  tool: 'Bash',
  args: {'command': 'ls -la'},
);

const _editToolWithHunk = ToolEvent(
  id: 'tc2',
  toolCallId: 'tc4',
  tool: 'edit',
  args: {
    'path': 'app/test/ui/chat/tool_request_card_test.dart',
    'hunks': [
      {
        'lines': [
          {'kind': 'context', 'oldLine': 16, 'newLine': 16, 'text': 'args: {'},
          {'kind': 'remove', 'oldLine': 17, 'text': "  tool: 'Edit',"},
          {'kind': 'add', 'newLine': 17, 'text': "  tool: 'edit',"},
          {'kind': 'context', 'oldLine': 18, 'newLine': 18, 'text': '},'},
        ],
      },
    ],
  },
);

void main() {
  group('ToolRequestCard (informational)', () {
    for (final status in ToolEventStatus.values) {
      testWidgets(
        '$status starts collapsed and toggles existing details',
        (tester) async {
          final tool = _bashTool.copyWith(status: status, error: 'tool error');
          final label = switch (status) {
            ToolEventStatus.pending || ToolEventStatus.allowed => 'RUNNING',
            ToolEventStatus.completed => 'DONE',
            ToolEventStatus.failed => 'FAILED',
            ToolEventStatus.denied => 'DENIED',
            ToolEventStatus.expired => 'EXPIRED',
          };
          final outcome = switch (status) {
            ToolEventStatus.pending || ToolEventStatus.allowed => '⏳ Running…',
            ToolEventStatus.completed => '✓ Done',
            ToolEventStatus.failed || ToolEventStatus.denied => '✗ tool error',
            ToolEventStatus.expired => '✗ Expired',
          };
          var decisions = 0;
          await tester.pumpWidget(_wrap(tool, onDecide: () => decisions++));
          expect(find.text('BASH'), findsOneWidget);
          expect(find.text(label), findsOneWidget);
          expect(find.byIcon(Icons.expand_more), findsOneWidget);
          expect(find.text('ls -la'), findsNothing);
          expect(find.text(outcome), findsNothing);
          await _toggle(tester);
          expect(find.text('ls -la'), findsOneWidget);
          expect(find.text(outcome), findsOneWidget);
          expect(find.byIcon(Icons.expand_less), findsOneWidget);
          await _toggle(tester);
          expect(find.text('ls -la'), findsNothing);
          expect(find.text(outcome), findsNothing);
          expect(find.text('Allow'), findsNothing);
          expect(find.text('Deny'), findsNothing);
          expect(decisions, 0);
        },
        variant: TargetPlatformVariant({
          TargetPlatform.android,
          TargetPlatform.iOS,
        }),
      );
    }

    for (final brightness in Brightness.values) {
      testWidgets(
        'single accessible header target in $brightness theme',
        (tester) async {
          final semantics = tester.ensureSemantics();
          try {
            await tester.pumpWidget(
              _wrap(
                _bashTool,
                theme: brightness == Brightness.dark
                    ? buildDarkTheme()
                    : buildLightTheme(),
              ),
            );
            final header = find.bySemanticsLabel('Bash, collapsed, RUNNING');
            expect(header, findsOneWidget);
            expect(
              tester.getSemantics(header),
              matchesSemantics(
                label: 'Bash, collapsed, RUNNING',
                isButton: true,
                hasTapAction: true,
                hasExpandedState: true,
              ),
            );
            expect(
              find.semantics.byPredicate(
                (node) =>
                    node.getSemanticsData().hasAction(SemanticsAction.tap),
              ),
              findsOneWidget,
            );
            // Invoke the accessibility action, not a second button/chevron target.
            tester.semantics.tap(
              find.semantics.byLabel('Bash, collapsed, RUNNING'),
            );
            await tester.pump();
            expect(find.text('ls -la'), findsOneWidget);
            expect(
              find.bySemanticsLabel('Bash, expanded, RUNNING'),
              findsOneWidget,
            );
            expect(
              find.semantics.byPredicate(
                (node) =>
                    node.getSemanticsData().hasAction(SemanticsAction.tap),
              ),
              findsOneWidget,
            );
            await _toggle(tester);
            expect(header, findsOneWidget);
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

    testWidgets('shows tool name and command', (tester) async {
      await tester.pumpWidget(_wrap(_bashTool));
      expect(find.text('BASH'), findsOneWidget);
      expect(find.text('ls -la'), findsNothing);
      await _toggle(tester);
      expect(find.text('ls -la'), findsOneWidget);
    });

    testWidgets('edit renders rich hunks with context lines', (tester) async {
      await tester.pumpWidget(_wrap(_editToolWithHunk));

      await tester.tap(find.text('EDIT'));
      await tester.pump();
      expect(
        find.textContaining('   16 args: {', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining("-  17   tool: 'Edit',", findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining("+  17   tool: 'edit',", findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining('   18 },', findRichText: true),
        findsOneWidget,
      );
    });

    testWidgets('pending state shows RUNNING and no Allow/Deny buttons', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(_bashTool));
      expect(find.text('RUNNING'), findsOneWidget);
      expect(find.text('Allow'), findsNothing);
      expect(find.text('Deny'), findsNothing);
      expect(find.textContaining('60s'), findsNothing);
    });

    testWidgets('completed state shows DONE', (tester) async {
      const done = ToolEvent(
        id: 'tc1',
        toolCallId: 'tc1',
        tool: 'Bash',
        args: {'command': 'ls'},
        status: ToolEventStatus.completed,
      );
      await tester.pumpWidget(_wrap(done));
      expect(find.text('DONE'), findsOneWidget);
      await _toggle(tester);
      expect(find.textContaining('Done'), findsAny);
    });

    testWidgets('denied state shows DENIED label', (tester) async {
      const denied = ToolEvent(
        id: 'tc1',
        toolCallId: 'tc1',
        tool: 'Bash',
        args: {'command': 'ls'},
        status: ToolEventStatus.denied,
        error: 'user denied',
      );
      await tester.pumpWidget(_wrap(denied));
      expect(find.text('DENIED'), findsOneWidget);
    });

    testWidgets('allowed state shows RUNNING (still in flight)', (
      tester,
    ) async {
      const allowed = ToolEvent(
        id: 'tc1',
        toolCallId: 'tc1',
        tool: 'Bash',
        args: {'command': 'ls'},
        status: ToolEventStatus.allowed,
      );
      await tester.pumpWidget(_wrap(allowed));
      expect(find.text('RUNNING'), findsOneWidget);
      expect(find.text('Allow'), findsNothing);
    });

    // Plan/32 — the card is colored by status: running blue, done green,
    // failed red. We assert the outcome line's color (the same _statusColor
    // drives the border / icon / tool name).
    Color? outcomeColor(WidgetTester tester, String text) =>
        tester.widget<Text>(find.text(text)).style?.color;

    testWidgets('completed → green "✓ Done"', (tester) async {
      const done = ToolEvent(
        id: 'tc1',
        toolCallId: 'tc1',
        tool: 'Bash',
        args: {'command': 'ls'},
        status: ToolEventStatus.completed,
      );
      await tester.pumpWidget(_wrap(done));
      await _toggle(tester);
      expect(outcomeColor(tester, '✓ Done'), AppColors.dark.success);
    });

    testWidgets('failed → red "✗ {error}" + FAILED label', (tester) async {
      const failed = ToolEvent(
        id: 'tc1',
        toolCallId: 'tc1',
        tool: 'Bash',
        args: {'command': 'exit 1'},
        status: ToolEventStatus.failed,
        error: 'command failed: exit 1',
      );
      await tester.pumpWidget(_wrap(failed));
      expect(find.text('FAILED'), findsOneWidget);
      await _toggle(tester);
      expect(
        outcomeColor(tester, '✗ command failed: exit 1'),
        AppColors.dark.error,
      );
    });

    testWidgets('running → blue "⏳ Running…"', (tester) async {
      // pending defaults
      await tester.pumpWidget(_wrap(_bashTool));
      await _toggle(tester);
      expect(outcomeColor(tester, '⏳ Running…'), AppColors.dark.accent);
    });
  });
}
