// Plan/28 Wave C — settings/quick-actions icon visibility in the
// chat input bar.

import 'package:app/ui/chat/widgets/input_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

void main() {
  Future<void> pumpBar(
    WidgetTester tester, {
    required bool disabled,
    required bool streaming,
    VoidCallback? onOpenQuickActions,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InputBar(
            disabled: disabled,
            streaming: streaming,
            onSend: (_) {},
            onCancel: () {},
            onOpenQuickActions: onOpenQuickActions,
          ),
        ),
      ),
    );
  }

  // Plan/28 — the quick-actions button is wrapped in a SizeTransition that
  // animates it in/out. When "hidden" the widget STAYS MOUNTED and only
  // collapses to zero width (it never leaves the tree), so `findsNothing` is
  // the wrong assertion. Instead: still present, but collapsed to width 0
  // (and therefore not tappable).
  final quickActionsKey = find.byKey(const Key('input-bar-quick-actions'));

  void expectCollapsed(WidgetTester tester) {
    expect(
      quickActionsKey,
      findsOneWidget,
      reason: 'stays mounted — SizeTransition collapses size, not the tree',
    );
    final sizeTransition = find.ancestor(
      of: quickActionsKey,
      matching: find.byType(SizeTransition),
    );
    expect(
      tester.getSize(sizeTransition).width,
      0,
      reason: 'collapsed to zero width when hidden',
    );
  }

  void expectExpanded(WidgetTester tester) {
    expect(quickActionsKey, findsOneWidget);
    final sizeTransition = find.ancestor(
      of: quickActionsKey,
      matching: find.byType(SizeTransition),
    );
    expect(
      tester.getSize(sizeTransition).width,
      greaterThan(0),
      reason: 'fully expanded when visible',
    );
  }

  testWidgets('quick actions button is visible when input is empty', (
    tester,
  ) async {
    await pumpBar(
      tester,
      disabled: false,
      streaming: false,
      onOpenQuickActions: () {},
    );
    await tester.pumpAndSettle();
    expectExpanded(tester);
  });

  testWidgets('quick actions button hides (collapses) while typing', (
    tester,
  ) async {
    await pumpBar(
      tester,
      disabled: false,
      streaming: false,
      onOpenQuickActions: () {},
    );
    await tester.enterText(find.byType(TextField), 'hello');
    // Let the SizeTransition finish collapsing (it animates out over 320ms).
    await tester.pumpAndSettle();
    expectCollapsed(tester);
  });

  testWidgets('quick actions button hides (collapses) when disabled', (
    tester,
  ) async {
    await pumpBar(
      tester,
      disabled: true,
      streaming: false,
      onOpenQuickActions: () {},
    );
    await tester.pumpAndSettle();
    expectCollapsed(tester);
  });

  testWidgets('quick actions button hides (collapses) while streaming', (
    tester,
  ) async {
    await pumpBar(
      tester,
      disabled: false,
      streaming: true,
      onOpenQuickActions: () {},
    );
    await tester.pumpAndSettle();
    expectCollapsed(tester);
  });

  // Plan/31 — `streaming` (the whole working turn, fed by vm.isWorking) must
  // lock the composer and turn the send button into "stop".
  testWidgets('streaming locks the field and shows the stop button', (
    tester,
  ) async {
    await pumpBar(
      tester,
      disabled: false,
      streaming: true,
      onOpenQuickActions: () {},
    );
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    expect(find.byIcon(LucideIcons.square), findsOneWidget); // stop
    expect(find.byIcon(LucideIcons.send), findsNothing);
    expect(find.byIcon(LucideIcons.mic), findsNothing);
  });

  testWidgets('tap fires onOpenQuickActions', (tester) async {
    var tapped = 0;
    await pumpBar(
      tester,
      disabled: false,
      streaming: false,
      onOpenQuickActions: () => tapped++,
    );
    await tester.tap(find.byKey(const Key('input-bar-quick-actions')));
    await tester.pump();
    expect(tapped, 1);
  });

  testWidgets('quick actions button hidden when callback is null', (
    tester,
  ) async {
    await pumpBar(tester, disabled: false, streaming: false);
    expect(find.byKey(const Key('input-bar-quick-actions')), findsNothing);
  });

  // Hardware keyboard (iPad keyboard case): plain Enter SENDS, Shift+Enter
  // inserts a newline. Touch behaviour is unaffected (soft Enter = newline via
  // performAction, send via the button).
  testWidgets('hardware Enter sends; Shift+Enter inserts a newline', (
    tester,
  ) async {
    final sent = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InputBar(
            disabled: false,
            streaming: false,
            onSend: sent.add,
            onCancel: () {},
          ),
        ),
      ),
    );

    final field = find.byType(TextField);
    await tester.enterText(field, 'hello');
    await tester.pump();

    // Plain Enter → send + clear.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(sent, ['hello']);
    expect(
      tester.widget<TextField>(field).controller!.text,
      isEmpty,
      reason: 'submit clears the field',
    );

    // Shift+Enter → newline, NOT a send.
    await tester.enterText(field, 'line1');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(sent, ['hello'], reason: 'shift+enter must not send');
    expect(
      tester.widget<TextField>(field).controller!.text,
      'line1\n',
      reason: 'shift+enter inserts a newline at the caret',
    );
  });

  // While streaming the composer is locked — hardware Enter must NOT send.
  testWidgets('hardware Enter does nothing while streaming', (tester) async {
    final sent = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InputBar(
            disabled: false,
            streaming: true,
            onSend: sent.add,
            onCancel: () {},
          ),
        ),
      ),
    );
    // The field is disabled while streaming; focus the composer subtree and
    // fire Enter anyway — it must be a no-op.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(sent, isEmpty);
  });
}
