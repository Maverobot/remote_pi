import 'package:app/domain/session_state.dart';
import 'package:app/domain/thinking.dart';
import 'package:app/ui/chat/widgets/thinking_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets(
      'Thinking group on $platform keeps full selectable text and header toggle',
      (tester) async {
        final semantics = tester.ensureSemantics();
        try {
          var expanded = true;
          var toggles = 0;
          ThinkingMsg member(String id, String text, ThinkingStatus status) {
            final observation = ThinkingObservation(
              scope: const ThinkingScope(sessionId: 'S', epoch: 'E'),
              messageId: id,
              revision: 1,
              status: status,
              text: text,
            );
            return ThinkingMsg(id: observation.id, observation: observation);
          }

          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(platform: platform),
              home: Scaffold(
                body: StatefulBuilder(
                  builder: (context, setState) => ThinkingCard.group(
                    [
                      member(
                        'first',
                        '  **Literal** first\n',
                        ThinkingStatus.incomplete,
                      ),
                      member('empty', '   ', ThinkingStatus.incomplete),
                      member(
                        'second',
                        'Second\n\nparagraph  ',
                        ThinkingStatus.complete,
                      ),
                    ],
                    expanded: expanded,
                    onToggle: () => setState(() {
                      toggles++;
                      expanded = !expanded;
                    }),
                  ),
                ),
              ),
            ),
          );
          const fullText = '  **Literal** first\n\n\nSecond\n\nparagraph  ';
          expect(find.text('Thinking'), findsOneWidget);
          expect(find.text('Incomplete'), findsOneWidget);
          expect(find.text(fullText), findsOneWidget);
          expect(find.byType(SelectableText), findsOneWidget);
          final header = find.bySemanticsLabel(
            'Thinking, expanded, Incomplete',
          );
          expect(tester.getSize(header).height, greaterThanOrEqualTo(48));
          expect(
            tester.getSemantics(header),
            matchesSemantics(
              label: 'Thinking, expanded, Incomplete',
              isButton: true,
              hasTapAction: true,
              hasExpandedState: true,
              isExpanded: true,
            ),
          );
          await tester.longPress(find.byType(SelectableText));
          await tester.pumpAndSettle();
          expect(toggles, 0);
          expect(find.text(fullText), findsOneWidget);
          await tester.tap(find.text('Thinking'));
          await tester.pumpAndSettle();
          expect(toggles, 1);
          expect(find.text(fullText), findsNothing);
          expect(
            find.bySemanticsLabel('Thinking, collapsed, Incomplete'),
            findsOneWidget,
          );
        } finally {
          semantics.dispose();
        }
      },
    );

    testWidgets(
      'ThinkingCard on $platform is collapsed, selectable and incomplete',
      (tester) async {
        final semantics = tester.ensureSemantics();
        try {
          var expanded = false;
          const thought = ThinkingObservation(
            scope: ThinkingScope(sessionId: 'S', epoch: 'E'),
            messageId: 'm',
            revision: 1,
            status: ThinkingStatus.incomplete,
            text: '  Summary\n\nSecond slot',
          );
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(platform: platform),
              home: Scaffold(
                body: StatefulBuilder(
                  builder: (context, setState) => ThinkingCard(
                    ThinkingMsg(id: thought.id, observation: thought),
                    expanded: expanded,
                    onToggle: () => setState(() => expanded = !expanded),
                  ),
                ),
              ),
            ),
          );
          expect(find.text(thought.text), findsNothing);
          expect(find.text('Incomplete'), findsOneWidget);
          expect(
            find.bySemanticsLabel('Thinking, collapsed, Incomplete'),
            findsOneWidget,
          );
          await tester.tap(find.text('Thinking'));
          await tester.pumpAndSettle();
          expect(find.byType(SelectableText), findsOneWidget);
          expect(find.text(thought.text), findsOneWidget);
          expect(
            find.bySemanticsLabel('Thinking, expanded, Incomplete'),
            findsOneWidget,
          );
        } finally {
          semantics.dispose();
        }
      },
    );
  }
  testWidgets('empty Thinking tombstone never creates a card', (tester) async {
    const thought = ThinkingObservation(
      scope: ThinkingScope(sessionId: 'S', epoch: 'E'),
      messageId: 'm',
      revision: 2,
      status: ThinkingStatus.complete,
      text: '',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ThinkingCard(
          ThinkingMsg(id: thought.id, observation: thought),
          expanded: true,
          onToggle: () {},
        ),
      ),
    );
    expect(find.text('Thinking'), findsNothing);
  });
}
