// Inline pi-ask form behavior. Wire parsing is covered in protocol tests.

import 'package:app/protocol/protocol.dart';
import 'package:app/ui/chat/states/chat_state.dart';
import 'package:app/ui/chat/widgets/extension_ui_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ExtensionUiRequest _richRequest({String id = 'tool:tc_1'}) =>
    ExtensionUiRequest(
      id: id,
      method: ExtensionUiMethod.select,
      title: 'Direction',
      options: const ['Alpha', 'Beta'],
      ask: AskEnrichmentWire(
        flowId: id,
        toolCallId: 'tc_1',
        source: 'tool',
        title: 'Direction',
        questions: const [
          AskQuestionWire(
            id: 'goal',
            label: 'Goal',
            prompt: "What's the goal?",
            type: AskQuestionWireType.single,
            required: true,
            options: [
              AskOptionWire(value: 'a', label: 'Alpha'),
              AskOptionWire(value: 'b', label: 'Beta'),
            ],
          ),
        ],
      ),
    );

ExtensionUiRequest _degradedInput() => const ExtensionUiRequest(
  id: 'flow:input',
  method: ExtensionUiMethod.input,
  title: 'Describe',
  placeholder: 'Describe the goal',
);

void main() {
  Future<void> pumpCard(
    WidgetTester tester, {
    required ExtensionUiRequest request,
    String? error,
    ExtensionUiResponse? submittedResponse,
    ExtensionUiFlowStatus status = ExtensionUiFlowStatus.pending,
    Future<void> Function(ExtensionUiResponse)? onRespond,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ExtensionUiCard(
              key: ValueKey(request.id),
              request: request,
              status: status,
              submittedResponse: submittedResponse,
              error: error,
              onRespond: onRespond ?? (_) async {},
            ),
          ),
        ),
      ),
    );
  }

  Finder submitButton() => find.widgetWithText(FilledButton, 'Submit');

  bool submitEnabled(WidgetTester tester) =>
      tester.widget<FilledButton>(submitButton()).onPressed != null;

  testWidgets('typing custom text alone enables Submit (rich flow)', (
    tester,
  ) async {
    await pumpCard(tester, request: _richRequest());
    expect(submitEnabled(tester), isFalse, reason: 'nothing answered yet');

    await tester.enterText(find.byType(TextField).first, 'my own answer');
    await tester.pump();

    expect(
      submitEnabled(tester),
      isTrue,
      reason: 'custom text counts as an answer without any option selected',
    );
  });

  testWidgets('typing enables Submit on the degraded input method', (
    tester,
  ) async {
    await pumpCard(tester, request: _degradedInput());
    expect(submitEnabled(tester), isFalse);

    await tester.enterText(find.byType(TextField), 'free text');
    await tester.pump();

    expect(submitEnabled(tester), isTrue);
  });

  testWidgets('selecting an option enables Submit and submit sends answers', (
    tester,
  ) async {
    final sent = <ExtensionUiResponse>[];
    await pumpCard(
      tester,
      request: _richRequest(),
      onRespond: (r) async => sent.add(r),
    );

    await tester.tap(find.text('Beta'));
    await tester.pump();
    expect(submitEnabled(tester), isTrue);

    await tester.tap(submitButton());
    await tester.pump();

    expect(sent, hasLength(1));
    final ask = sent.single.ask!;
    expect(ask.flowId, 'tool:tc_1');
    expect(ask.isCancel, isFalse);
    expect(ask.answers['goal']!.values, ['b']);
    // Card does NOT complete optimistically: it spins until completed/error.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets(
    'rejection stops the spinner for retry; clearing the error mid-retry '
    'does not un-spin the in-flight submit',
    (tester) async {
      final sent = <ExtensionUiResponse>[];
      Future<void> onRespond(ExtensionUiResponse r) async => sent.add(r);

      await pumpCard(tester, request: _richRequest(), onRespond: onRespond);
      await tester.tap(find.text('Alpha'));
      await tester.pump();
      await tester.tap(submitButton());
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      // pi-ask rejected → error arrives → spinner off, message shown.
      await pumpCard(
        tester,
        request: _richRequest(),
        error: 'Unknown option value.',
        onRespond: onRespond,
      );
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Unknown option value.'), findsOneWidget);
      expect(submitEnabled(tester), isTrue, reason: 'retry possible');

      // Retry → viewmodel clears the error (non-null → null). The submit is
      // in flight again; the cleared error must NOT reset the spinner (that
      // would re-enable the buttons and allow a double submit).
      await tester.tap(submitButton());
      await tester.pump();
      await pumpCard(tester, request: _richRequest(), onRespond: onRespond);
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(sent, hasLength(2));
    },
  );

  testWidgets('Cancel sends cancellation and waits for confirmation', (
    tester,
  ) async {
    final sent = <ExtensionUiResponse>[];
    await pumpCard(
      tester,
      request: _richRequest(),
      onRespond: (r) async => sent.add(r),
    );
    await tester.tap(find.widgetWithText(OutlinedButton, 'Cancel'));
    await tester.pump();
    expect(sent, hasLength(1));
    expect(sent.single.cancelled, isTrue);
    expect(sent.single.ask?.isCancel, isTrue);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Completed'), findsNothing);
  });

  testWidgets('system back leaves the route without sending an answer', (
    tester,
  ) async {
    final sent = <ExtensionUiResponse>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => Scaffold(
                  body: SingleChildScrollView(
                    child: ExtensionUiCard(
                      request: _richRequest(),
                      onRespond: (response) async => sent.add(response),
                    ),
                  ),
                ),
              ),
            ),
            child: const Text('Open chat'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open chat'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Open chat'), findsOneWidget);
    expect(sent, isEmpty);
  });

  for (final status in [
    ExtensionUiFlowStatus.completed,
    ExtensionUiFlowStatus.replaced,
  ]) {
    testWidgets('$status is inert and does not claim a draft was accepted', (
      tester,
    ) async {
      final sent = <ExtensionUiResponse>[];
      await pumpCard(
        tester,
        request: _richRequest(),
        onRespond: (r) async => sent.add(r),
      );
      await tester.enterText(find.byType(TextField), 'Unconfirmed draft');
      await pumpCard(
        tester,
        request: _richRequest(),
        status: status,
        onRespond: (r) async => sent.add(r),
      );
      expect(
        find.text(
          status == ExtensionUiFlowStatus.completed ? 'Completed' : 'Replaced',
        ),
        findsOneWidget,
      );
      expect(find.text("What's the goal?"), findsOneWidget);
      expect(find.text('Unconfirmed draft'), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(find.byType(FilledButton), findsNothing);
      expect(find.byType(OutlinedButton), findsNothing);
      expect(sent, isEmpty);
    });
  }

  testWidgets('timeout offers retry without claiming completion', (
    tester,
  ) async {
    final sent = <ExtensionUiResponse>[];
    await pumpCard(
      tester,
      request: _richRequest(),
      onRespond: (r) async => sent.add(r),
    );
    await tester.tap(find.text('Alpha'));
    await tester.pump();
    await tester.tap(submitButton());
    await tester.pump(const Duration(seconds: 25));
    expect(
      find.text('No response from Pi yet — retry or cancel.'),
      findsOneWidget,
    );
    expect(find.text('Completed'), findsNothing);
    expect(submitEnabled(tester), isTrue);
    await tester.tap(submitButton());
    await tester.pump();
    expect(sent, hasLength(2));
    await pumpCard(
      tester,
      request: _richRequest(),
      status: ExtensionUiFlowStatus.completed,
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets(
    'replay preserves draft; a new flow with the same question id starts empty',
    (tester) async {
      await pumpCard(tester, request: _richRequest());
      await tester.enterText(find.byType(TextField), 'My draft');
      await pumpCard(tester, request: _richRequest());
      expect(find.text('My draft'), findsOneWidget);
      await pumpCard(tester, request: _richRequest(id: 'tool:new'));
      expect(find.text('My draft'), findsNothing);
      expect(submitEnabled(tester), isFalse);
    },
  );

  testWidgets(
    'single, multi and preview questions submit together with custom text',
    (tester) async {
      final sent = <ExtensionUiResponse>[];
      const request = ExtensionUiRequest(
        id: 'group',
        method: ExtensionUiMethod.select,
        ask: AskEnrichmentWire(
          flowId: 'group',
          source: 'tool',
          questions: [
            AskQuestionWire(
              id: 'single',
              label: '',
              required: false,
              prompt: 'Single question',
              type: AskQuestionWireType.single,
              options: [AskOptionWire(value: 's', label: 'Single option')],
            ),
            AskQuestionWire(
              id: 'multi',
              label: '',
              required: false,
              prompt: 'Multi question',
              type: AskQuestionWireType.multi,
              options: [
                AskOptionWire(value: 'a', label: 'Multi A'),
                AskOptionWire(value: 'b', label: 'Multi B'),
              ],
            ),
            AskQuestionWire(
              id: 'preview',
              label: '',
              required: false,
              prompt: 'Preview question',
              type: AskQuestionWireType.preview,
              options: [
                AskOptionWire(
                  value: 'p',
                  label: 'Preview option',
                  preview: 'Preview content',
                ),
              ],
            ),
          ],
        ),
      );
      await pumpCard(
        tester,
        request: request,
        onRespond: (r) async => sent.add(r),
      );
      expect(find.byType(ExtensionUiCard), findsOneWidget);
      await tester.tap(find.text('Single option'));
      await tester.enterText(find.byType(TextField).at(0), 'Custom single');
      await tester.ensureVisible(find.text('Multi A'));
      await tester.tap(find.text('Multi A'));
      await tester.ensureVisible(find.text('Multi B'));
      await tester.tap(find.text('Multi B'));
      await tester.enterText(find.byType(TextField).at(1), 'Custom multi');
      await tester.ensureVisible(find.text('Preview option'));
      await tester.tap(find.text('Preview option'));
      expect(find.text('Preview content'), findsOneWidget);
      await tester.pump();
      await tester.ensureVisible(submitButton());
      await tester.tap(submitButton());
      await tester.pump();
      expect(sent, hasLength(1));
      final answers = sent.single.ask!.answers;
      expect(answers.keys, ['single', 'multi', 'preview']);
      expect(answers['single']!.values, isEmpty);
      expect(answers['single']!.customText, 'Custom single');
      expect(answers['multi']!.values, ['a', 'b']);
      expect(answers['multi']!.customText, 'Custom multi');
      expect(answers['preview']!.values, ['p']);
      await pumpCard(
        tester,
        request: request,
        status: ExtensionUiFlowStatus.completed,
        submittedResponse: sent.single,
      );
      expect(find.text('Submitted on this device'), findsOneWidget);
      for (final text in [
        'Single question',
        'Custom single',
        'Multi question',
        'Multi A',
        'Multi B',
        'Custom multi',
        'Preview question',
        'Preview option',
      ]) {
        expect(find.text(text), findsOneWidget);
      }
      expect(find.text('Single option'), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(find.byType(FilledButton), findsNothing);
    },
  );

  testWidgets('completed card renders a fallback-title question only once', (
    tester,
  ) async {
    const prompt = 'Which direction should we take?';
    const request = ExtensionUiRequest(
      id: 'fallback-title',
      method: ExtensionUiMethod.select,
      title: prompt,
      ask: AskEnrichmentWire(
        flowId: 'fallback-title',
        source: 'tool',
        questions: [
          AskQuestionWire(
            id: 'direction',
            label: '',
            prompt: prompt,
            type: AskQuestionWireType.single,
            required: false,
            options: [AskOptionWire(value: 'a', label: 'Alpha')],
          ),
        ],
      ),
    );
    await pumpCard(
      tester,
      request: request,
      status: ExtensionUiFlowStatus.completed,
      submittedResponse: ExtensionUiResponse(
        id: 'fallback-title',
        ask: const AskResponseEnrichmentWire(
          flowId: 'fallback-title',
          answers: {
            'direction': AskAnswerWire(values: ['a'], customText: 'My reason'),
          },
        ),
      ),
    );
    expect(find.text(prompt), findsOneWidget);
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('My reason'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('required question renders the advisory chip', (tester) async {
    await pumpCard(tester, request: _richRequest());
    expect(find.text('required'), findsOneWidget);
  });

  testWidgets('defensive degraded notify renders its message once', (
    tester,
  ) async {
    await pumpCard(
      tester,
      request: const ExtensionUiRequest(
        id: 'notify:1',
        method: ExtensionUiMethod.notify,
        message: 'Clarification resolved.',
      ),
    );

    expect(find.text('Clarification resolved.'), findsOneWidget);
  });
}
