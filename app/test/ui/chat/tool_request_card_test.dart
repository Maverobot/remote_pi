import 'dart:async';
import 'dart:ui' show SemanticsAction, Tristate;

import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/widgets/tool_request_card.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(ToolEvent tool, {ThemeData? theme, VoidCallback? onDecide}) {
  var expanded = false;
  return MaterialApp(
    theme: theme,
    home: Scaffold(
      body: SingleChildScrollView(
        child: StatefulBuilder(
          builder: (context, setState) => ToolRequestCard(
            tool: tool,
            expanded: expanded,
            onToggle: () => setState(() => expanded = !expanded),
            onDecide: (_, _) => onDecide?.call(),
          ),
        ),
      ),
    ),
  );
}

Future<void> _toggle(WidgetTester tester) async {
  await tester.tap(find.text('BASH'));
  await tester.pump();
}

Future<void> _openCopyOptions(WidgetTester tester) async {
  expect(find.text('Copy input'), findsNothing);
  expect(find.text('Copy output'), findsNothing);
  await tester.tap(find.byTooltip('Copy options'));
  await tester.pumpAndSettle();
}

Future<void> _copyFromMenu(WidgetTester tester, String label) async {
  await _openCopyOptions(tester);
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
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
  final copied = <String>[];
  setUp(() {
    copied.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

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
          expect(find.text('ls -la'), findsOneWidget);
          expect(find.text(r'$ '), findsNothing);
          expect(find.text(outcome), findsNothing);
          await _toggle(tester);
          expect(find.text('ls -la'), findsOneWidget);
          expect(find.text(outcome), findsOneWidget);
          expect(find.byIcon(Icons.expand_less), findsOneWidget);
          await _toggle(tester);
          expect(find.text('ls -la'), findsOneWidget);
          expect(find.text(r'$ '), findsNothing);
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
            final header = find.bySemanticsLabel(
              'Bash, collapsed, RUNNING, ls -la',
            );
            expect(header, findsOneWidget);
            expect(
              tester.getSemantics(header),
              matchesSemantics(
                label: 'Bash, collapsed, RUNNING, ls -la',
                isButton: true,
                hasTapAction: true,
                hasExpandedState: true,
              ),
            );
            final copyOptions = find.byTooltip('Copy options');
            expect(copyOptions, findsOneWidget);
            expect(
              tester
                  .getSemantics(copyOptions)
                  .getSemanticsData()
                  .hasAction(SemanticsAction.tap),
              isTrue,
            );
            expect(
              find.descendant(of: header, matching: copyOptions),
              findsNothing,
            );
            expect(find.bySemanticsLabel('Copy input'), findsNothing);
            expect(find.bySemanticsLabel('Copy output'), findsNothing);
            expect(
              tester.getSemantics(copyOptions).getSemanticsData().tooltip,
              'Copy options',
            );
            tester.semantics.tap(
              find.semantics.byPredicate(
                (node) => node.getSemanticsData().tooltip == 'Copy options',
              ),
            );
            await tester.pumpAndSettle();
            expect(
              tester
                  .getSemantics(find.bySemanticsLabel('Copy output'))
                  .getSemanticsData()
                  .flagsCollection
                  .isEnabled,
              Tristate.isFalse,
            );
            tester.semantics.tap(find.semantics.byLabel('Copy input'));
            await tester.pumpAndSettle();
            expect(copied, ['ls -la']);
            expect(header, findsOneWidget);
            // Invoke the accessibility action, not a second button/chevron target.
            tester.semantics.tap(
              find.semantics.byLabel('Bash, collapsed, RUNNING, ls -la'),
            );
            await tester.pump();
            expect(find.text('ls -la'), findsOneWidget);
            expect(
              find.bySemanticsLabel('Bash, expanded, RUNNING'),
              findsOneWidget,
            );
            expect(copyOptions, findsOneWidget);
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
      expect(find.text('ls -la'), findsOneWidget);
      expect(find.text(r'$ '), findsNothing);
      await _toggle(tester);
      expect(find.text('ls -la'), findsOneWidget);
    });

    testWidgets('known tools preview only command or path aliases', (
      tester,
    ) async {
      for (final (name, args, preview) in [
        ('bAsH', {'command': 'pwd', 'timeout': 30}, 'pwd'),
        ('Read', {'file_path': 'a.dart', 'offset': 4}, 'a.dart'),
        ('read', {'path': 'b.dart', 'limit': 10}, 'b.dart'),
        ('EDIT', {'file_path': 'c.dart', 'oldText': 'not a preview'}, 'c.dart'),
        ('edit', {'path': 'd.dart', 'hunks': 'not a preview'}, 'd.dart'),
        (
          'Write',
          {'file_path': 'e.dart', 'content': 'not a preview'},
          'e.dart',
        ),
        ('write', {'path': 'f.dart', 'content': 'not a preview'}, 'f.dart'),
        (
          'read',
          {'file_path': 'first.dart', 'path': 'second.dart'},
          'first.dart',
        ),
      ]) {
        await tester.pumpWidget(
          _wrap(
            ToolEvent(
              id: 'preview',
              toolCallId: 'preview',
              tool: name,
              args: args,
            ),
          ),
        );
        expect(find.text(name.toUpperCase()), findsOneWidget);
        expect(find.text(preview), findsOneWidget);
        expect(find.textContaining('not a preview'), findsNothing);
        expect(find.text(r'$ '), findsNothing);
        expect(find.text('⏳ Running…'), findsNothing);
      }
    });

    testWidgets('unknown or malformed args keep name-only collapsed header', (
      tester,
    ) async {
      for (final (name, args) in <(String, dynamic)>[
        ('custom', {'command': 'do not preview', 'path': 'secret.txt'}),
        ('bash', null),
        ('bash', 'do not preview'),
        ('bash', <String>[]),
        ('bash', <String, dynamic>{}),
        ('bash', {'command': null}),
        ('bash', {'command': 42}),
        ('bash', {'command': ' \n\t '}),
        (
          'read',
          {
            'path': ['secret.txt'],
          },
        ),
        ('edit', {'file_path': 42}),
        ('write', {'content': 'do not preview'}),
      ]) {
        await tester.pumpWidget(
          _wrap(
            ToolEvent(
              id: 'preview',
              toolCallId: 'preview',
              tool: name,
              args: args,
            ),
          ),
        );
        expect(find.text(name.toUpperCase()), findsOneWidget);
        expect(find.text('RUNNING'), findsOneWidget);
        expect(
          find.bySemanticsLabel('$name, collapsed, RUNNING'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets(
      'long multiline previews stay below header on one line; details unchanged',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(320, 844));
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(() {
          tester.platformDispatcher.clearTextScaleFactorTestValue();
          return tester.binding.setSurfaceSize(null);
        });
        final longPart = List.filled(12, 'long-segment').join('/');
        for (final (name, key, value, preview, details) in [
          (
            'bash',
            'command',
            '  echo\n\t$longPart  ',
            'echo $longPart',
            '  echo\n\t$longPart  ',
          ),
          (
            'write',
            'path',
            '  src/\r\n$longPart  ',
            'src/ $longPart',
            'write   src/\r\n$longPart  ',
          ),
        ]) {
          await tester.pumpWidget(
            _wrap(
              ToolEvent(
                id: 'preview',
                toolCallId: 'preview',
                tool: name,
                args: {key: value},
              ),
            ),
          );
          final subtitle = find.text(preview);
          final text = tester.widget<Text>(subtitle);
          expect(text.maxLines, 1);
          expect(text.softWrap, isFalse);
          expect(text.overflow, TextOverflow.ellipsis);
          expect(
            tester.getTopLeft(subtitle).dy,
            greaterThanOrEqualTo(
              tester.getBottomLeft(find.text(name.toUpperCase())).dy,
            ),
          );
          expect(tester.getSize(subtitle).width, lessThanOrEqualTo(292));
          expect(find.text(details), findsNothing);
          expect(tester.takeException(), isNull);
          // The subtitle itself is inside the single header tap target.
          await tester.tap(subtitle);
          await tester.pump();
          expect(find.text(preview), findsNothing);
          expect(find.text(details), findsOneWidget);
          expect(find.text('⏳ Running…'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.tap(find.text(name.toUpperCase()));
          await tester.pump();
          expect(subtitle, findsOneWidget);
          expect(find.text(details), findsNothing);
        }
      },
    );

    testWidgets(
      'copy actions preserve full Bash input/output and expansion at large text',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(320, 844));
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(() {
          tester.platformDispatcher.clearTextScaleFactorTestValue();
          return tester.binding.setSurfaceSize(null);
        });
        const command =
            '  printf "first line"\n\tprintf "second line with long arguments"  ';
        const output = 'first line\nsecond line\n';
        var decisions = 0;
        await tester.pumpWidget(
          _wrap(
            const ToolEvent(
              id: 'copy',
              toolCallId: 'copy',
              tool: 'Bash',
              args: {'command': command},
              result: output,
              status: ToolEventStatus.completed,
            ),
            onDecide: () => decisions++,
          ),
        );
        final semantics = tester.ensureSemantics();
        try {
          for (final expanded in [false, true]) {
            expect(
              find.byIcon(expanded ? Icons.expand_less : Icons.expand_more),
              findsOneWidget,
            );
            expect(find.text(output), expanded ? findsOneWidget : findsNothing);
            final menu = find.byTooltip('Copy options');
            expect(tester.getSize(menu).width, greaterThanOrEqualTo(48));
            expect(tester.getSize(menu).height, greaterThanOrEqualTo(48));
            expect(
              tester.getRect(menu).overlaps(tester.getRect(find.text('BASH'))),
              isFalse,
            );
            expect(
              tester.getTopLeft(menu).dy,
              lessThan(tester.getBottomLeft(find.text('BASH')).dy),
            );
            await _openCopyOptions(tester);
            expect(find.bySemanticsLabel('Copy input'), findsOneWidget);
            expect(find.bySemanticsLabel('Copy output'), findsOneWidget);
            expect(
              find.byIcon(expanded ? Icons.expand_less : Icons.expand_more),
              findsOneWidget,
            );
            await tester.tap(find.text('Copy input'));
            await tester.pumpAndSettle();
            await tester.pump();
            expect(copied.last, command);
            expect(find.text('Input copied'), findsOneWidget);
            await _copyFromMenu(tester, 'Copy output');
            await tester.pump();
            expect(copied.last, output);
            expect(
              find.byIcon(expanded ? Icons.expand_less : Icons.expand_more),
              findsOneWidget,
            );
            expect(decisions, 0);
            expect(tester.takeException(), isNull);
            if (!expanded) await _toggle(tester);
          }
          expect(copied, [command, output, command, output]);
        } finally {
          semantics.dispose();
        }
      },
    );

    testWidgets(
      'copies readable JSON, text, error and combined outputs without placeholders',
      (tester) async {
        for (final (args, input, result, error, output)
            in <(Object?, String, Object?, String?, String)>[
              (
                {'path': 'a.dart', 'content': 'line\nnext'},
                '{\n  "path": "a.dart",\n  "content": "line\\nnext"\n}',
                {'ok': true},
                null,
                '{\n  "ok": true\n}',
              ),
              (
                'raw input\n',
                'raw input\n',
                'raw output\n',
                null,
                'raw output\n',
              ),
              (['a', 2], '[\n  "a",\n  2\n]', false, null, 'false'),
              ({}, '{}', 0, null, '0'),
              ('input', 'input', null, 'raw error\n', 'raw error\n'),
              (
                'input',
                'input',
                'partial\n',
                'failure\n',
                'partial\n\nfailure\n',
              ),
            ]) {
          await tester.pumpWidget(
            _wrap(
              ToolEvent(
                id: 'copy',
                toolCallId: 'copy',
                tool: 'custom',
                args: args,
                result: result,
                error: error,
                status: error == null
                    ? ToolEventStatus.completed
                    : ToolEventStatus.failed,
              ),
            ),
          );
          await _copyFromMenu(tester, 'Copy input');
          await tester.pump();
          expect(copied.last, input);
          await _copyFromMenu(tester, 'Copy output');
          await tester.pump();
          expect(copied.last, output);
          expect(find.byIcon(Icons.expand_more), findsOneWidget);
          expect(find.text('OUTPUT'), findsNothing);
          expect(find.text('ERROR'), findsNothing);
          await tester.tap(find.text('CUSTOM'));
          await tester.pump();
          if (result != null) {
            expect(find.text('OUTPUT'), findsOneWidget);
            final resultText = result is String ? result : output;
            expect(find.text(resultText), findsOneWidget);
          }
          if (error != null) {
            expect(find.text('ERROR'), findsOneWidget);
            expect(find.text(error), findsOneWidget);
          }
          expect(tester.takeException(), isNull);
        }
      },
    );

    testWidgets('missing input and empty output leave copy actions disabled', (
      tester,
    ) async {
      for (final result in [null, '']) {
        await tester.pumpWidget(
          _wrap(
            ToolEvent(
              id: 'empty',
              toolCallId: 'empty',
              tool: 'custom',
              args: null,
              result: result,
              error: '',
            ),
          ),
        );
        final semantics = tester.ensureSemantics();
        await _openCopyOptions(tester);
        for (final label in ['Copy input', 'Copy output']) {
          final item = find.bySemanticsLabel(label);
          expect(
            tester
                .getSemantics(item)
                .getSemanticsData()
                .flagsCollection
                .isEnabled,
            Tristate.isFalse,
          );
          await tester.tap(find.text(label));
          await tester.pumpAndSettle();
          expect(find.text(label), findsOneWidget);
        }
        // Disabled entries keep the menu open and never copy placeholders.
        await tester.tapAt(const Offset(10, 500));
        await tester.pumpAndSettle();
        semantics.dispose();
        expect(copied, isEmpty);
        expect(find.byIcon(Icons.expand_more), findsOneWidget);
        await tester.tap(find.text('CUSTOM'));
        await tester.pump();
        expect(find.text('OUTPUT'), findsNothing);
        expect(find.text('ERROR'), findsNothing);
      }
    });

    testWidgets(
      'copy feedback waits for clipboard success and tolerates disposal',
      (tester) async {
        var completion = Completer<void>();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, (call) async {
              if (call.method == 'Clipboard.setData') await completion.future;
              return null;
            });
        await tester.pumpWidget(_wrap(_bashTool));
        await _copyFromMenu(tester, 'Copy input');
        await tester.pump();
        expect(find.text('Input copied'), findsNothing);
        completion.complete();
        await tester.pumpAndSettle();
        expect(find.text('Input copied'), findsOneWidget);
        completion = Completer<void>();
        await _copyFromMenu(tester, 'Copy input');
        await tester.pumpWidget(const SizedBox());
        completion.complete();
        await tester.pump();
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'clipboard failure does not report success or expand the card',
      (tester) async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, (call) async {
              if (call.method == 'Clipboard.setData') {
                throw PlatformException(code: 'unavailable');
              }
              return null;
            });
        await tester.pumpWidget(_wrap(_bashTool));
        await _copyFromMenu(tester, 'Copy input');
        await tester.pump();
        expect(find.text('Input copied'), findsNothing);
        expect(find.text('Could not copy input'), findsOneWidget);
        expect(find.byIcon(Icons.expand_more), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('edit renders rich hunks with context lines', (tester) async {
      await tester.pumpWidget(_wrap(_editToolWithHunk));

      expect(
        find.text('app/test/ui/chat/tool_request_card_test.dart'),
        findsOneWidget,
      );
      expect(
        find.textContaining('   16 args: {', findRichText: true),
        findsNothing,
      );
      await tester.tap(find.text('EDIT'));
      await tester.pump();
      expect(
        find.text('app/test/ui/chat/tool_request_card_test.dart'),
        findsNothing,
      );
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
