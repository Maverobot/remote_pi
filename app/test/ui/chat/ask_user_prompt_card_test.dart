import 'package:app/data/local/records/message_record.dart';
import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/widgets/ask_user_prompt_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AskUserPromptCard legacy history', () {
    for (final state in ['pending', 'answered', 'cancelled']) {
      testWidgets('saved $state prompt is readable but cannot be answered', (
        tester,
      ) async {
        final saved = MessageRecord.fromJson({
          'id': 'legacy-prompt',
          'seq': 0,
          'role': 'askUser',
          'ts': 1,
          'ask_user': {
            'question': 'Choose a route',
            'context': 'Existing task context',
            'options': [
              {'title': 'Route A', 'description': 'The shorter route'},
            ],
            'allow_multiple': true,
            'allow_freeform': true,
            'allow_comment': true,
            'resolved': state != 'pending',
            'cancelled': state == 'cancelled',
            if (state == 'answered') 'answer_label': 'Route A',
          },
        });
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: AskUserPromptCard(
                prompt: saved.toChatMessage() as AskUserPromptMsg,
              ),
            ),
          ),
        );

        expect(find.text('Choose a route'), findsOneWidget);
        expect(find.text('Existing task context'), findsOneWidget);
        expect(find.text('Legacy prompt — read-only.'), findsOneWidget);
        expect(
          find.text(switch (state) {
            'answered' => 'Answered',
            'cancelled' => 'Cancelled',
            _ => 'Archived',
          }),
          findsOneWidget,
        );
        if (state != 'cancelled') {
          expect(find.text('Route A'), findsOneWidget);
        }
        if (state == 'pending') {
          expect(find.text('The shorter route'), findsOneWidget);
          await tester.tap(find.text('Route A'));
          await tester.pump();
          expect(find.text('Archived'), findsOneWidget);
        }
        expect(find.byType(TextField), findsNothing);
        expect(find.byType(FilledButton), findsNothing);
        expect(find.byType(OutlinedButton), findsNothing);
        expect(find.byType(Checkbox), findsNothing);
      });
    }
  });
}
