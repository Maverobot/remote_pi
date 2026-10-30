import 'dart:io';
import 'package:app/domain/session_state.dart';

import 'package:app/data/actions/actions_repository.dart';
import 'package:app/data/images/image_picker_service.dart';
import 'package:app/data/local/boxes.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/repositories/session_read_repository.dart';
import 'package:app/data/voice/speech_service.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/chat/states/chat_state.dart';
import 'package:app/ui/chat/attachment/viewmodels/attachment_viewmodel.dart';
import 'package:app/ui/chat/chat_page.dart';
import 'package:app/ui/chat/viewmodels/chat_viewmodel.dart';
import 'package:app/ui/chat/voice/viewmodels/voice_input_viewmodel.dart';
import 'package:app/ui/chat/widgets/extension_ui_card.dart';
import 'package:app/ui/chat/widgets/input_bar.dart';
import 'package:app/ui/chat/widgets/message_bubble.dart';
import 'package:app/ui/chat/widgets/thinking_card.dart';
import 'package:app/ui/chat/widgets/streaming_bubble.dart';
import 'package:app/ui/chat/widgets/tool_request_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:provider/provider.dart';

import 'extension_ui_test_support.dart';

class _Speech implements SpeechService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Picker implements IImagePickerService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ExtensionUiRequest _request(String id, {String? toolCallId}) =>
    ExtensionUiRequest(
      id: id,
      method: ExtensionUiMethod.select,
      title: 'Choose direction $id',
      ask: AskEnrichmentWire(
        flowId: id,
        toolCallId: toolCallId,
        source: 'tool',
        questions: const [
          AskQuestionWire(
            id: 'goal',
            label: '',
            required: false,
            prompt: 'What is the goal?',
            type: AskQuestionWireType.multi,
            options: [AskOptionWire(value: 'a', label: 'Alpha')],
          ),
        ],
      ),
    );

void main() {
  late Directory directory;
  setUpAll(() async {
    directory = Directory.systemTemp.createTempSync('rp_inline_page_');
    await LocalBoxes.initForTest(directory.path);
  });
  tearDownAll(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  Future<void> deliver(
    WidgetTester tester,
    ExtensionUiTestChannel channel,
    ServerMessage message,
  ) async {
    await tester.runAsync(() async {
      channel.push(message);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
  }

  testWidgets(
    'Thinking choices survive revisions, history and lazy eviction; page recreation collapses',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final h = (await tester.runAsync(extensionUiHarness))!;
      final voice = VoiceInputViewModel(_Speech());
      final actions = ActionsRepository(h.conn);
      final attach = AttachmentViewModel(_Picker(), actions);
      Future<void> showChat() => tester.pumpWidget(
        MaterialApp(
          home: MultiProvider(
            providers: [
              ChangeNotifierProvider<ChatViewModel>.value(value: h.vm),
              ChangeNotifierProvider<Preferences>.value(value: h.prefs),
              ChangeNotifierProvider<VoiceInputViewModel>.value(value: voice),
              ChangeNotifierProvider<AttachmentViewModel>.value(value: attach),
            ],
            child: const ChatPage(),
          ),
        ),
      );
      Pong snapshot(int revision, String text) => Pong.fromJson({
        'in_reply_to': 'thinking:m',
        'thinking': {
          'session_id': 'thinking-ui',
          'epoch': 'E',
          'message_id': 'm',
          'room_id': 'main',
          'revision': revision,
          'status': 'complete',
          'text': text,
          'ts': 1,
        },
      });
      try {
        await tester.runAsync(h.vm.clearActiveSession);
        await showChat();
        await deliver(
          tester,
          h.ch,
          ServerMessage.fromJson({
            'type': 'session_history',
            'in_reply_to': h.ch.sent.whereType<SessionSync>().last.id,
            'session_started_at': 1,
            'room_id': 'main',
            'events': [],
            'eos': true,
            'truncated': false,
            'thinking_history': {
              'kind': 'reply',
              'session_id': 'thinking-ui',
              'epoch': 'E',
              'count': 0,
              'truncated': false,
            },
          }),
        );
        await deliver(tester, h.ch, snapshot(1, 'Summary A\n\nSummary B'));
        expect(find.text('Thinking'), findsOneWidget);
        expect(find.text('Summary A\n\nSummary B'), findsNothing);
        await tester.tap(find.text('Thinking'));
        await tester.pumpAndSettle();
        expect(find.text('Summary A\n\nSummary B'), findsOneWidget);
        await deliver(tester, h.ch, snapshot(2, 'Revised provider summary'));
        expect(find.text('Revised provider summary'), findsOneWidget);
        await deliver(
          tester,
          h.ch,
          SessionHistory(
            inReplyTo: 'legacy-replay',
            sessionStartedAt: 1,
            events: const [
              UserInputEvt(ts: 0, id: 'thinking-question', text: 'Question'),
            ],
            eos: true,
          ),
        );
        expect(find.text('Revised provider summary'), findsOneWidget);
        final original = find.byType(ThinkingCard).evaluate().single;
        for (var i = 0; i < 24; i++) {
          await deliver(
            tester,
            h.ch,
            UserInput(
              id: 'thinking-after-$i',
              text: 'Later $i\nSecond line\nThird line',
            ),
          );
        }
        expect(original.mounted, isFalse);
        final scrollable = find
            .descendant(
              of: find.byType(ListView).first,
              matching: find.byType(Scrollable),
            )
            .first;
        await tester.scrollUntilVisible(
          find.text('Thinking'),
          300,
          scrollable: scrollable,
        );
        expect(find.text('Revised provider summary'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        await showChat();
        await tester.scrollUntilVisible(
          find.text('Thinking'),
          300,
          scrollable: scrollable,
        );
        expect(find.text('Revised provider summary'), findsNothing);
        await deliver(tester, h.ch, snapshot(3, ''));
        expect(find.byType(ThinkingCard), findsNothing);
        expect(
          (h.vm.state as ChatReady).messages.whereType<ThinkingMsg>(),
          isEmpty,
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        h.vm.dispose();
        voice.dispose();
        attach.dispose();
        actions.dispose();
        h.sync.dispose();
        h.conn.dispose();
        h.prefs.dispose();
      }
    },
  );

  for (final fromHistory in [false, true]) {
    testWidgets('tool choices survive updates, streaming and lazy eviction '
        '(history: $fromHistory)', (tester) async {
      final copied = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              copied.add((call.arguments as Map)['text'] as String);
            }
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final h = (await tester.runAsync(extensionUiHarness))!;
      final voice = VoiceInputViewModel(_Speech());
      final actions = ActionsRepository(h.conn);
      final attach = AttachmentViewModel(_Picker(), actions);
      Future<void> showChat() => tester.pumpWidget(
        MaterialApp(
          home: MultiProvider(
            providers: [
              ChangeNotifierProvider<ChatViewModel>.value(value: h.vm),
              ChangeNotifierProvider<Preferences>.value(value: h.prefs),
              ChangeNotifierProvider<VoiceInputViewModel>.value(value: voice),
              ChangeNotifierProvider<AttachmentViewModel>.value(value: attach),
            ],
            child: const ChatPage(),
          ),
        ),
      );
      try {
        await tester.runAsync(h.vm.clearActiveSession);
        await showChat();
        if (fromHistory) {
          await deliver(
            tester,
            h.ch,
            SessionHistory(
              inReplyTo: 'sync',
              sessionStartedAt: 1,
              eos: true,
              roomId: 'main',
              events: const [
                ToolRequestEvt(
                  ts: 1,
                  toolCallId: 'collapse-bash',
                  tool: 'bash',
                  args: {'command': 'echo retained'},
                ),
                ToolResultEvt(ts: 2, toolCallId: 'collapse-bash', result: 'ok'),
              ],
            ),
          );
        } else {
          await deliver(
            tester,
            h.ch,
            ToolRequest(
              toolCallId: 'collapse-bash',
              tool: 'bash',
              args: const {'command': 'echo retained'},
            ),
          );
        }
        expect(find.text('BASH'), findsOneWidget);
        expect(find.text('echo retained'), findsOneWidget);
        expect(find.text(r'$ '), findsNothing);
        expect(find.text('✓ Done'), findsNothing);
        expect(find.text('⏳ Running…'), findsNothing);
        expect(find.text('Copy input'), findsNothing);
        await tester.tap(find.byTooltip('Copy options'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Copy input'));
        await tester.pumpAndSettle();
        await tester.pump();
        expect(copied, ['echo retained']);
        expect(find.text(r'$ '), findsNothing);
        await tester.tap(find.text('BASH'));
        await tester.pump();
        expect(find.text('echo retained'), findsOneWidget);
        expect(find.text(r'$ '), findsOneWidget);
        // Hiding even the only row must not overwrite its expansion choice.
        await h.prefs.setHideToolCalls(true);
        await tester.pump();
        expect(find.byType(ToolRequestCard), findsNothing);
        expect(find.text('Nothing here'), findsOneWidget);
        await h.prefs.setHideToolCalls(false);
        await tester.pump();
        expect(find.text('echo retained'), findsOneWidget);
        expect(find.text(r'$ '), findsOneWidget);
        await deliver(
          tester,
          h.ch,
          ToolResult(toolCallId: 'collapse-bash', result: 'ok'),
        );
        expect(find.text('✓ Done'), findsOneWidget);
        expect(find.text('ok'), findsOneWidget);
        expect(find.text('Copy output'), findsNothing);
        await tester.tap(find.byTooltip('Copy options'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Copy output'));
        await tester.pumpAndSettle();
        await tester.pump();
        expect(copied, ['echo retained', 'ok']);
        expect(find.text(r'$ '), findsOneWidget);
        await deliver(
          tester,
          h.ch,
          ToolRequest(
            toolCallId: 'collapse-read',
            tool: 'read',
            args: const {'path': 'hidden.txt'},
          ),
        );
        expect(find.text('READ'), findsOneWidget);
        expect(find.text('hidden.txt'), findsOneWidget);
        expect(find.text('path=hidden.txt'), findsNothing);
        await deliver(
          tester,
          h.ch,
          UserInput(id: 'later-turn', text: 'Later turn'),
        );
        for (final delta in ['Streaming', ' more']) {
          await deliver(
            tester,
            h.ch,
            AgentChunk(inReplyTo: 'later-turn', delta: delta),
          );
          expect(find.text('echo retained'), findsOneWidget);
          expect(find.text(r'$ '), findsOneWidget);
          expect(find.text('path=hidden.txt'), findsNothing);
        }
        await deliver(tester, h.ch, AgentDone(inReplyTo: 'later-turn'));
        // Menu/header ink animations temporarily keep their lazy row alive.
        await tester.pumpAndSettle();
        final originalCard = find
            .ancestor(
              of: find.text('BASH'),
              matching: find.byType(ToolRequestCard),
            )
            .evaluate()
            .single;
        for (var i = 0; i < 24; i++) {
          await deliver(
            tester,
            h.ch,
            UserInput(
              id: 'collapse-later-$i',
              text: 'Later message $i\nMore text\nThird line',
            ),
          );
        }
        final scrollable = find
            .descendant(
              of: find.byType(ListView).first,
              matching: find.byType(Scrollable),
            )
            .first;
        // Observe actual disposal, not merely a row outside the viewport.
        expect(find.text('BASH'), findsNothing);
        expect(originalCard.mounted, isFalse);
        await tester.scrollUntilVisible(
          find.text('BASH'),
          300,
          scrollable: scrollable,
        );
        expect(find.text('echo retained'), findsOneWidget);
        expect(find.text(r'$ '), findsOneWidget);
        await tester.ensureVisible(find.text('BASH'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('BASH'));
        await tester.pump();
        expect(find.text('echo retained'), findsOneWidget);
        expect(find.text(r'$ '), findsNothing);
        expect(find.text('✓ Done'), findsNothing);
        expect(find.text('⏳ Running…'), findsNothing);
        await tester.scrollUntilVisible(
          find.text('Later message 23\nMore text\nThird line'),
          -300,
          scrollable: scrollable,
        );
        await deliver(
          tester,
          h.ch,
          ToolResult(toolCallId: 'collapse-read', result: 'ok'),
        );
        await tester.scrollUntilVisible(
          find.text('BASH'),
          300,
          scrollable: scrollable,
        );
        expect(find.text('echo retained'), findsOneWidget);
        expect(find.text(r'$ '), findsNothing);
        expect(find.text('✓ Done'), findsNothing);
        expect(find.text('⏳ Running…'), findsNothing);
        expect(find.text('path=hidden.txt'), findsNothing);
        await tester.ensureVisible(find.text('BASH'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('BASH'));
        await tester.pump();
        expect(find.text('echo retained'), findsOneWidget);
        expect(find.text(r'$ '), findsOneWidget);
        // Choices are screen-local, not persisted in the repository.
        await tester.pumpWidget(const SizedBox());
        await showChat();
        await tester.scrollUntilVisible(
          find.text('BASH'),
          300,
          scrollable: scrollable,
        );
        expect(find.text('echo retained'), findsOneWidget);
        expect(find.text(r'$ '), findsNothing);
        expect(find.text('✓ Done'), findsNothing);
        expect(find.text('⏳ Running…'), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        h.vm.dispose();
        voice.dispose();
        attach.dispose();
        actions.dispose();
        h.sync.dispose();
        h.conn.dispose();
        h.prefs.dispose();
      }
    });
  }

  testWidgets(
    'compaction choices survive history, streaming and lazy eviction independently',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final h = (await tester.runAsync(extensionUiHarness))!;
      final voice = VoiceInputViewModel(_Speech());
      final actions = ActionsRepository(h.conn);
      final attach = AttachmentViewModel(_Picker(), actions);
      Future<void> showChat() => tester.pumpWidget(
        MaterialApp(
          home: MultiProvider(
            providers: [
              ChangeNotifierProvider<ChatViewModel>.value(value: h.vm),
              ChangeNotifierProvider<Preferences>.value(value: h.prefs),
              ChangeNotifierProvider<VoiceInputViewModel>.value(value: voice),
              ChangeNotifierProvider<AttachmentViewModel>.value(value: attach),
            ],
            child: const ChatPage(),
          ),
        ),
      );
      SessionHistory history({bool both = false}) => SessionHistory(
        inReplyTo: 'sync',
        sessionStartedAt: 1,
        eos: true,
        roomId: 'main',
        events: [
          const CompactionEvt(
            ts: 101,
            summary: 'History recap',
            tokensBefore: 111,
          ),
          if (both)
            const CompactionEvt(
              ts: 102,
              summary: 'Live recap',
              tokensBefore: 222,
            ),
        ],
      );
      try {
        await tester.runAsync(h.vm.clearActiveSession);
        await showChat();
        await deliver(tester, h.ch, history());
        expect(find.text('~111 tokens'), findsOneWidget);
        expect(find.text('History recap'), findsNothing);
        await deliver(
          tester,
          h.ch,
          Compaction(ts: 102, summary: 'Live recap', tokensBefore: 222),
        );
        expect(find.text('~222 tokens'), findsOneWidget);
        expect(find.text('Live recap'), findsNothing);
        await tester.tap(find.text('~111 tokens'));
        await tester.pump();
        expect(find.text('History recap'), findsOneWidget);
        expect(find.text('Live recap'), findsNothing);
        await tester.tap(find.text('~222 tokens'));
        await tester.pump();
        expect(find.text('History recap'), findsOneWidget);
        expect(find.text('Live recap'), findsOneWidget);
        await tester.tap(find.text('~111 tokens'));
        await tester.pump();
        await deliver(tester, h.ch, history(both: true));
        expect(find.text('History recap'), findsNothing);
        expect(find.text('Live recap'), findsOneWidget);
        await deliver(
          tester,
          h.ch,
          UserInput(id: 'after-compaction', text: 'Continue'),
        );
        await deliver(
          tester,
          h.ch,
          AgentChunk(inReplyTo: 'after-compaction', delta: 'Reply'),
        );
        expect(find.text('History recap'), findsNothing);
        expect(find.text('Live recap'), findsOneWidget);
        await deliver(tester, h.ch, AgentDone(inReplyTo: 'after-compaction'));
        // Let header ink animations release their temporary row keep-alives.
        await tester.pumpAndSettle();
        final originalCard = find
            .ancestor(
              of: find.text('~222 tokens'),
              matching: find.byType(CompactionBubble),
            )
            .evaluate()
            .single;
        for (var i = 0; i < 24; i++) {
          await deliver(
            tester,
            h.ch,
            UserInput(
              id: 'after-compaction-$i',
              text: 'New message $i\nMore text\nThird line',
            ),
          );
        }
        expect(find.text('~222 tokens'), findsNothing);
        expect(originalCard.mounted, isFalse);
        final scrollable = find
            .descendant(
              of: find.byType(ListView).first,
              matching: find.byType(Scrollable),
            )
            .first;
        await tester.scrollUntilVisible(
          find.text('~111 tokens'),
          300,
          scrollable: scrollable,
        );
        expect(find.text('History recap'), findsNothing);
        expect(find.text('Live recap'), findsOneWidget);
        await tester.ensureVisible(find.text('~111 tokens'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('~111 tokens'));
        await tester.pump();
        expect(find.text('History recap'), findsOneWidget);
        expect(find.text('Live recap'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        await showChat();
        await tester.scrollUntilVisible(
          find.text('~111 tokens'),
          300,
          scrollable: scrollable,
        );
        expect(find.text('History recap'), findsNothing);
        expect(find.text('Live recap'), findsNothing);
        expect(find.text('~222 tokens'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        h.vm.dispose();
        voice.dispose();
        attach.dispose();
        actions.dispose();
        h.sync.dispose();
        h.conn.dispose();
        h.prefs.dispose();
      }
    },
  );

  for (final requestBeforeTool in [false, true]) {
    testWidgets('live question follows its intro and tool, not later replies '
        '(request before tool: $requestBeforeTool)', (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 2000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final h = (await tester.runAsync(extensionUiHarness))!;
      final voice = VoiceInputViewModel(_Speech());
      final actions = ActionsRepository(h.conn);
      final attach = AttachmentViewModel(_Picker(), actions);
      try {
        await tester.runAsync(h.vm.clearActiveSession);
        await tester.pumpWidget(
          MaterialApp(
            home: MultiProvider(
              providers: [
                ChangeNotifierProvider<ChatViewModel>.value(value: h.vm),
                ChangeNotifierProvider<Preferences>.value(value: h.prefs),
                ChangeNotifierProvider<VoiceInputViewModel>.value(value: voice),
                ChangeNotifierProvider<AttachmentViewModel>.value(
                  value: attach,
                ),
              ],
              child: const ChatPage(),
            ),
          ),
        );
        final request = _request('live', toolCallId: 'ask-tool');
        final tool = ToolRequest(
          toolCallId: 'ask-tool',
          tool: 'ask_user',
          args: const {},
        );
        final card = find.byType(ExtensionUiCard);
        Future<void> burst(List<ServerMessage> messages) async {
          await tester.runAsync(() async {
            for (final message in messages) {
              h.ch.push(message);
            }
            // Let the real sync writer and repository drain AFTER the burst.
            await Future<void>.delayed(const Duration(milliseconds: 50));
          });
          await tester.pump();
        }

        final intro = AgentChunk(
          inReplyTo: 'turn',
          delta: 'Explanation before asking',
        );
        if (requestBeforeTool) {
          await burst([intro, request]);
          expect(
            tester.getBottomLeft(find.byType(StreamingBubble)).dy,
            lessThan(tester.getTopLeft(card).dy),
          );
          await tester.enterText(
            find.descendant(of: card, matching: find.byType(TextField)),
            'Keep through anchoring',
          );
          await burst([tool]);
          expect(find.text('Keep through anchoring'), findsOneWidget);
        } else {
          // Production order, with no artificial gap between chunk/tool/request.
          await burst([intro, tool, request]);
        }
        void expectOrder({required bool toolVisible}) {
          final introBubble = find.byWidgetPredicate(
            (w) =>
                w is AssistantBubble &&
                w.message.text == 'Explanation before asking',
          );
          expect(
            tester.getBottomLeft(introBubble).dy,
            lessThan(tester.getTopLeft(card).dy),
          );
          if (toolVisible) {
            expect(find.byType(ToolRequestCard), findsOneWidget);
            expect(
              tester.getBottomLeft(find.byType(ToolRequestCard)).dy,
              lessThan(tester.getTopLeft(card).dy),
            );
          }
          final later = find.byWidgetPredicate(
            (w) => w is AssistantBubble && w.message.text == 'Later answer',
          );
          if (later.evaluate().isNotEmpty) {
            expect(
              tester.getBottomLeft(card).dy,
              lessThan(tester.getTopLeft(later).dy),
            );
          }
        }

        expectOrder(toolVisible: true);
        await burst([
          const ExtensionUiRequest(
            id: 'live',
            method: ExtensionUiMethod.notify,
          ),
          ToolResult(toolCallId: 'ask-tool', result: 'done'),
          AgentChunk(inReplyTo: 'turn', delta: 'Later answer'),
        ]);
        expect(
          tester.getBottomLeft(card).dy,
          lessThan(tester.getTopLeft(find.byType(StreamingBubble)).dy),
        );
        await burst([AgentDone(inReplyTo: 'turn')]);
        expectOrder(toolVisible: true);
        final replay = SessionHistory(
          inReplyTo: 'sync',
          sessionStartedAt: 1,
          eos: true,
          roomId: 'main',
          events: const [
            AgentMessageEvt(
              ts: 1,
              inReplyTo: 'turn',
              text: 'Explanation before asking',
            ),
            ToolRequestEvt(
              ts: 2,
              toolCallId: 'ask-tool',
              tool: 'ask_user',
              args: {},
            ),
            ToolResultEvt(ts: 3, toolCallId: 'ask-tool', result: 'done'),
            AgentMessageEvt(ts: 4, inReplyTo: 'turn', text: 'Later answer'),
          ],
        );
        await burst([replay, request]);
        expect(card, findsOneWidget);
        expectOrder(toolVisible: true);
        await h.prefs.setHideToolCalls(true);
        await tester.pump();
        expect(find.byType(ToolRequestCard), findsNothing);
        expectOrder(toolVisible: false);
        await h.prefs.setHideToolCalls(false);
        await tester.pump();
        expectOrder(toolVisible: true);
        await burst([
          SessionHistory(
            inReplyTo: 'sync',
            sessionStartedAt: 1,
            eos: true,
            roomId: 'main',
            truncated: true,
            events: const [
              AgentMessageEvt(ts: 4, inReplyTo: 'turn', text: 'Later answer'),
            ],
          ),
        ]);
        // A resolved tool removed by truncation uses the existing fallback,
        // not the provisional tail, which would drift after this later reply.
        expect(
          tester.getBottomLeft(card).dy,
          lessThan(tester.getTopLeft(find.byType(AssistantBubble)).dy),
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        h.vm.dispose();
        voice.dispose();
        attach.dispose();
        actions.dispose();
        h.sync.dispose();
        h.conn.dispose();
        h.prefs.dispose();
      }
    });
  }

  for (final outcome in [
    'submitted',
    'failed',
    'rejected',
    'cancelled',
    'other client',
    'late rejection',
  ]) {
    testWidgets('completed question shows only a local submission: $outcome', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(390, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final h = (await tester.runAsync(extensionUiHarness))!;
      final voice = VoiceInputViewModel(_Speech());
      final actions = ActionsRepository(h.conn);
      final attach = AttachmentViewModel(_Picker(), actions);
      try {
        await tester.runAsync(h.vm.clearActiveSession);
        await tester.pumpWidget(
          MaterialApp(
            home: MultiProvider(
              providers: [
                ChangeNotifierProvider<ChatViewModel>.value(value: h.vm),
                ChangeNotifierProvider<Preferences>.value(value: h.prefs),
                ChangeNotifierProvider<VoiceInputViewModel>.value(value: voice),
                ChangeNotifierProvider<AttachmentViewModel>.value(
                  value: attach,
                ),
              ],
              child: const ChatPage(),
            ),
          ),
        );
        await deliver(tester, h.ch, _request('summary'));
        final card = find.byType(ExtensionUiCard);
        final custom = find.descendant(
          of: card,
          matching: find.byType(TextField),
        );
        await tester.tap(find.text('Alpha'));
        await tester.enterText(custom, 'Submitted custom text');
        if (outcome == 'failed') h.ch.sendError = StateError('offline');
        if (outcome != 'other client') {
          await tester.tap(
            outcome == 'cancelled'
                ? find.widgetWithText(OutlinedButton, 'Cancel')
                : find.widgetWithText(FilledButton, 'Submit'),
          );
          await tester.pump();
        }
        h.ch.sendError = null;
        if (outcome == 'rejected') {
          await deliver(
            tester,
            h.ch,
            const ExtensionUiRequest(
              id: 'summary',
              method: ExtensionUiMethod.notify,
              notifyType: 'warning',
              message: 'Rejected',
            ),
          );
        }
        if (outcome == 'submitted') {
          // After the retry timeout, edits are drafts, NOT the sent payload.
          await tester.pump(const Duration(seconds: 26));
          await tester.enterText(custom, 'Unsubmitted later edit');
        }
        await deliver(
          tester,
          h.ch,
          const ExtensionUiRequest(
            id: 'summary',
            method: ExtensionUiMethod.notify,
          ),
        );
        if (outcome == 'late rejection') {
          expect(find.text('Submitted on this device'), findsOneWidget);
          await deliver(
            tester,
            h.ch,
            const ExtensionUiRequest(
              id: 'summary',
              method: ExtensionUiMethod.notify,
              notifyType: 'warning',
              message: 'Flow is no longer active',
            ),
          );
          expect(find.text('Flow is no longer active'), findsNothing);
        }
        expect(find.text('What is the goal?'), findsOneWidget);
        expect(
          find.descendant(of: card, matching: find.byType(TextField)),
          findsNothing,
        );
        if (outcome == 'submitted') {
          expect(find.text('Submitted on this device'), findsOneWidget);
          expect(find.text('Alpha'), findsOneWidget);
          expect(find.text('Submitted custom text'), findsOneWidget);
          expect(find.text('Unsubmitted later edit'), findsNothing);
        } else {
          expect(find.text('Completed — answer not synced'), findsOneWidget);
          expect(find.text('Submitted on this device'), findsNothing);
          expect(find.text('Submitted custom text'), findsNothing);
          expect(find.text('Alpha'), findsNothing);
        }
        await deliver(tester, h.ch, _request('summary'));
        expect(card, findsOneWidget);
        expect(
          find.text(
            outcome == 'submitted'
                ? 'Submitted on this device'
                : 'Completed — answer not synced',
          ),
          findsOneWidget,
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        h.vm.dispose();
        voice.dispose();
        attach.dispose();
        actions.dispose();
        h.sync.dispose();
        h.conn.dispose();
        h.prefs.dispose();
      }
    });
  }

  testWidgets(
    'empty chat shows an inline request beside the chat controls; completion lasts only until leaving',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final h = (await tester.runAsync(extensionUiHarness))!;
      final voice = VoiceInputViewModel(_Speech());
      final actions = ActionsRepository(h.conn);
      final attach = AttachmentViewModel(_Picker(), actions);
      var vm = h.vm;
      Future<void> showChat() => tester.pumpWidget(
        MaterialApp(
          home: MultiProvider(
            providers: [
              ChangeNotifierProvider<ChatViewModel>.value(value: vm),
              ChangeNotifierProvider<Preferences>.value(value: h.prefs),
              ChangeNotifierProvider<VoiceInputViewModel>.value(value: voice),
              ChangeNotifierProvider<AttachmentViewModel>.value(value: attach),
            ],
            child: const ChatPage(initialTitle: 'Inline chat'),
          ),
        ),
      );
      await showChat();
      expect(find.text('Nothing here'), findsOneWidget);
      await deliver(tester, h.ch, _request('f1'));
      expect(find.byType(ExtensionUiCard), findsOneWidget);
      expect(find.text('Nothing here'), findsNothing);
      expect(find.text('Inline chat'), findsOneWidget);
      expect(find.byType(InputBar), findsOneWidget);
      expect(find.byType(Scaffold), findsOneWidget);
      expect(
        tester.getBottomLeft(find.byType(ExtensionUiCard)).dy,
        lessThanOrEqualTo(tester.getTopLeft(find.byType(InputBar)).dy),
      );
      await tester.enterText(
        find.descendant(
          of: find.byType(ExtensionUiCard),
          matching: find.byType(TextField),
        ),
        'Unsent local draft',
      );
      await tester.pump();
      h.ch.sendError = StateError('offline');
      for (var attempt = 0; attempt < 2; attempt++) {
        await tester.ensureVisible(find.widgetWithText(FilledButton, 'Submit'));
        await tester.tap(find.widgetWithText(FilledButton, 'Submit'));
        await tester.pump();
        expect(
          find.text('Not connected — check the link to Pi and retry.'),
          findsOneWidget,
        );
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, 'Submit'))
              .onPressed,
          isNotNull,
        );
      }
      h.ch.sendError = null;
      // Another client can resolve this flow: neither local send succeeded.
      await deliver(
        tester,
        h.ch,
        const ExtensionUiRequest(id: 'f1', method: ExtensionUiMethod.notify),
      );
      expect(find.text('Completed'), findsOneWidget);
      expect(find.text('Unsent local draft'), findsNothing);
      expect(
        find.descendant(
          of: find.byType(ExtensionUiCard),
          matching: find.byType(TextField),
        ),
        findsNothing,
      );
      await deliver(tester, h.ch, _request('f1'));
      expect(find.byType(ExtensionUiCard), findsOneWidget);
      expect(find.text('Completed'), findsOneWidget);
      expect(h.ch.sent.whereType<ExtensionUiResponse>(), isEmpty);

      await tester.pumpWidget(const SizedBox());
      vm.dispose();
      vm = ChatViewModel(
        SessionReadRepository(LocalBoxes()),
        h.sync,
        h.conn,
        h.prefs,
        ExtensionUiTestStorage(),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await showChat();
      expect(find.byType(ExtensionUiCard), findsNothing);
      expect(find.text('Nothing here'), findsOneWidget);
      await deliver(tester, h.ch, _request('f2'));
      expect(find.text('Choose direction f2'), findsOneWidget);
      expect(find.text('Unsent local draft'), findsNothing);

      await tester.pumpWidget(const SizedBox());
      vm.dispose();
      voice.dispose();
      attach.dispose();
      actions.dispose();
      h.sync.dispose();
      h.conn.dispose();
      h.prefs.dispose();
    },
  );

  testWidgets(
    'draft survives replay, streaming, list reindexing and scrolling; new flow is empty',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final h = (await tester.runAsync(extensionUiHarness))!;
      final voice = VoiceInputViewModel(_Speech());
      final actions = ActionsRepository(h.conn);
      final attach = AttachmentViewModel(_Picker(), actions);
      await tester.pumpWidget(
        MaterialApp(
          home: MultiProvider(
            providers: [
              ChangeNotifierProvider<ChatViewModel>.value(value: h.vm),
              ChangeNotifierProvider<Preferences>.value(value: h.prefs),
              ChangeNotifierProvider<VoiceInputViewModel>.value(value: voice),
              ChangeNotifierProvider<AttachmentViewModel>.value(value: attach),
            ],
            child: const ChatPage(),
          ),
        ),
      );
      await deliver(
        tester,
        h.ch,
        UserInput(id: 'anchor', text: 'Before the question'),
      );
      await deliver(tester, h.ch, _request('draft'));
      final card = find.byType(ExtensionUiCard);
      final custom = find.descendant(
        of: card,
        matching: find.byType(TextField),
      );
      await tester.tap(find.text('Alpha'));
      await tester.enterText(custom, 'Keep this draft');
      await deliver(tester, h.ch, _request('draft'));
      expect(card, findsOneWidget);
      expect(find.text('Keep this draft'), findsOneWidget);
      await deliver(
        tester,
        h.ch,
        AgentChunk(inReplyTo: 'anchor', delta: 'Streaming after question'),
      );
      expect(
        tester.getTopLeft(find.byType(StreamingBubble)).dy,
        greaterThanOrEqualTo(tester.getBottomLeft(card).dy),
      );
      await deliver(tester, h.ch, AgentDone(inReplyTo: 'anchor'));
      // Move the card beyond the lazy list's cache while messages shift indices.
      for (var i = 0; i < 18; i++) {
        await deliver(
          tester,
          h.ch,
          UserInput(
            id: 'later-$i',
            text: 'Later message $i\nMore text\nThird line',
          ),
        );
      }
      final scrollable = find
          .descendant(
            of: find.byType(ListView).first,
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.text('Choose direction draft'),
        300,
        scrollable: scrollable,
      );
      await tester.ensureVisible(custom);
      expect(find.text('Keep this draft'), findsOneWidget);
      await tester.ensureVisible(find.widgetWithText(FilledButton, 'Submit'));
      await tester.tap(find.widgetWithText(FilledButton, 'Submit'));
      await tester.pump();
      expect(
        h.ch.sent
            .whereType<ExtensionUiResponse>()
            .single
            .ask!
            .answers['goal']!
            .customText,
        'Keep this draft',
      );
      expect(
        h.ch.sent
            .whereType<ExtensionUiResponse>()
            .single
            .ask!
            .answers['goal']!
            .values,
        ['a'],
      );
      expect(find.text('Completed'), findsNothing);
      await deliver(tester, h.ch, _request('new'));
      await tester.scrollUntilVisible(
        find.text('Choose direction new'),
        -300,
        scrollable: scrollable,
      );
      await tester.ensureVisible(find.text('Choose direction new'));
      expect(find.text('Keep this draft'), findsNothing);
      final newCard = find.ancestor(
        of: find.text('Choose direction new'),
        matching: find.byType(ExtensionUiCard),
      );
      final submit = find.descendant(
        of: newCard,
        matching: find.widgetWithText(FilledButton, 'Submit'),
      );
      expect(tester.widget<FilledButton>(submit).onPressed, isNull);
      await tester.scrollUntilVisible(
        find.text('Choose direction draft'),
        300,
        scrollable: scrollable,
      );
      expect(find.text('Replaced'), findsOneWidget);
      final oldCard = find.ancestor(
        of: find.text('Choose direction draft'),
        matching: find.byType(ExtensionUiCard),
      );
      expect(
        find.descendant(of: oldCard, matching: find.byType(FilledButton)),
        findsNothing,
      );

      await tester.pumpWidget(const SizedBox());
      h.vm.dispose();
      voice.dispose();
      attach.dispose();
      actions.dispose();
      h.sync.dispose();
      h.conn.dispose();
      h.prefs.dispose();
    },
  );

  testWidgets(
    'history with shared turn IDs and identical assistant segments keeps one anchored draft',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final h = (await tester.runAsync(extensionUiHarness))!;
      final voice = VoiceInputViewModel(_Speech());
      final actions = ActionsRepository(h.conn);
      final attach = AttachmentViewModel(_Picker(), actions);
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: MultiProvider(
              providers: [
                ChangeNotifierProvider<ChatViewModel>.value(value: h.vm),
                ChangeNotifierProvider<Preferences>.value(value: h.prefs),
                ChangeNotifierProvider<VoiceInputViewModel>.value(value: voice),
                ChangeNotifierProvider<AttachmentViewModel>.value(
                  value: attach,
                ),
              ],
              child: const ChatPage(),
            ),
          ),
        );
        const segment = AgentMessageEvt(
          ts: 2,
          inReplyTo: 'turn',
          text: 'Same reply',
        );
        const events = <SessionHistoryEvent>[
          UserInputEvt(ts: 1, id: 'turn', text: 'Question'),
          ToolRequestEvt(ts: 2, toolCallId: 'tool', tool: 'read', args: {}),
          segment,
          segment,
        ];
        SessionHistory history(List<SessionHistoryEvent> events) =>
            SessionHistory(
              inReplyTo: 'sync',
              sessionStartedAt: 1,
              eos: true,
              roomId: 'main',
              events: events,
            );
        await deliver(tester, h.ch, history(events));
        expect(
          (h.vm.state as ChatReady).messages.map((message) => message.id),
          ['turn', 'tool', 'turn', 'turn'],
        );
        await deliver(tester, h.ch, _request('history-flow'));
        expect(tester.takeException(), isNull);
        final card = find.byType(ExtensionUiCard);
        expect(card, findsOneWidget);
        expect(find.byType(AssistantBubble), findsNWidgets(2));
        for (final bubble in find.byType(AssistantBubble).evaluate()) {
          expect(
            tester.getBottomLeft(find.byWidget(bubble.widget)).dy,
            lessThan(tester.getTopLeft(card).dy),
          );
        }
        await tester.tap(find.text('Alpha'));
        await tester.enterText(
          find.descendant(of: card, matching: find.byType(TextField)),
          'Retained draft',
        );
        await deliver(
          tester,
          h.ch,
          AgentChunk(inReplyTo: 'turn', delta: 'More'),
        );
        await deliver(tester, h.ch, AgentDone(inReplyTo: 'turn'));
        // A later identical segment must not take the original anchor's place.
        final appended = history([...events, segment]);
        await deliver(tester, h.ch, appended);
        await h.prefs.setHideToolCalls(true);
        await tester.pump();
        await deliver(tester, h.ch, appended);
        await h.prefs.setHideToolCalls(false);
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(card, findsOneWidget);
        expect(find.byType(AssistantBubble), findsNWidgets(3));
        final tops = find
            .byType(AssistantBubble)
            .evaluate()
            .map(
              (element) => tester.getTopLeft(find.byWidget(element.widget)).dy,
            );
        expect(
          tops.where((top) => top < tester.getTopLeft(card).dy),
          hasLength(2),
        );
        expect(
          tops.where((top) => top > tester.getBottomLeft(card).dy),
          hasLength(1),
        );
        expect(find.text('Retained draft'), findsOneWidget);
        await tester.ensureVisible(find.widgetWithText(FilledButton, 'Submit'));
        await tester.tap(find.widgetWithText(FilledButton, 'Submit'));
        await tester.pump();
        final answer = h.ch.sent
            .whereType<ExtensionUiResponse>()
            .single
            .ask!
            .answers['goal']!;
        expect(answer.values, ['a']);
        expect(answer.customText, 'Retained draft');
      } finally {
        await tester.pumpWidget(const SizedBox());
        h.vm.dispose();
        voice.dispose();
        attach.dispose();
        actions.dispose();
        h.sync.dispose();
        h.conn.dispose();
        h.prefs.dispose();
      }
    },
  );

  testWidgets(
    'truncated history keeps a card beside its surviving assistant segment',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final h = (await tester.runAsync(extensionUiHarness))!;
      final voice = VoiceInputViewModel(_Speech());
      final actions = ActionsRepository(h.conn);
      final attach = AttachmentViewModel(_Picker(), actions);
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: MultiProvider(
              providers: [
                ChangeNotifierProvider<ChatViewModel>.value(value: h.vm),
                ChangeNotifierProvider<Preferences>.value(value: h.prefs),
                ChangeNotifierProvider<VoiceInputViewModel>.value(value: voice),
                ChangeNotifierProvider<AttachmentViewModel>.value(
                  value: attach,
                ),
              ],
              child: const ChatPage(),
            ),
          ),
        );
        const earlier = AgentMessageEvt(
          ts: 1,
          inReplyTo: 'turn',
          text: 'Earlier segment',
        );
        const anchor = AgentMessageEvt(
          ts: 2,
          inReplyTo: 'turn',
          text: 'Question context',
        );
        const later = AgentMessageEvt(
          ts: 3,
          inReplyTo: 'turn',
          text: 'Later answer',
        );
        SessionHistory history(
          List<SessionHistoryEvent> events, {
          bool truncated = false,
        }) => SessionHistory(
          inReplyTo: 'sync',
          sessionStartedAt: 1,
          eos: true,
          roomId: 'main',
          truncated: truncated,
          events: events,
        );
        await deliver(tester, h.ch, history([earlier, anchor]));
        await deliver(tester, h.ch, _request('trimmed'));
        await deliver(
          tester,
          h.ch,
          const ExtensionUiRequest(
            id: 'trimmed',
            method: ExtensionUiMethod.notify,
          ),
        );
        final card = find.byType(ExtensionUiCard);
        for (final replay in [
          history([earlier, anchor, later]),
          history([anchor, later], truncated: true),
          history([anchor, later], truncated: true),
        ]) {
          await deliver(tester, h.ch, replay);
          expect(tester.takeException(), isNull);
          expect(card, findsOneWidget);
          final replies = find.byType(AssistantBubble).evaluate().toList();
          final contextBubble = replies.firstWhere(
            (e) =>
                (e.widget as AssistantBubble).message.text ==
                'Question context',
          );
          final laterBubble = replies.firstWhere(
            (e) => (e.widget as AssistantBubble).message.text == 'Later answer',
          );
          expect(
            tester.getBottomLeft(find.byWidget(contextBubble.widget)).dy,
            lessThan(tester.getTopLeft(card).dy),
          );
          expect(
            tester.getBottomLeft(card).dy,
            lessThan(tester.getTopLeft(find.byWidget(laterBubble.widget)).dy),
          );
        }
        // No matching context remains: use the existing missing-anchor
        // fallback rather than attaching the card to the surviving reply.
        await deliver(tester, h.ch, history([later], truncated: true));
        expect(card, findsOneWidget);
        expect(
          tester.getBottomLeft(card).dy,
          lessThan(tester.getTopLeft(find.byType(AssistantBubble)).dy),
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        h.vm.dispose();
        voice.dispose();
        attach.dispose();
        actions.dispose();
        h.sync.dispose();
        h.conn.dispose();
        h.prefs.dispose();
      }
    },
  );

  testWidgets(
    'new session removes completed and pending cards and blocks old responses',
    (tester) async {
      final h = (await tester.runAsync(extensionUiHarness))!;
      final voice = VoiceInputViewModel(_Speech());
      final actions = ActionsRepository(h.conn);
      final attach = AttachmentViewModel(_Picker(), actions);
      try {
        await tester.runAsync(h.vm.clearActiveSession);
        await tester.pumpWidget(
          MaterialApp(
            home: MultiProvider(
              providers: [
                ChangeNotifierProvider<ChatViewModel>.value(value: h.vm),
                ChangeNotifierProvider<Preferences>.value(value: h.prefs),
                ChangeNotifierProvider<VoiceInputViewModel>.value(value: voice),
                ChangeNotifierProvider<AttachmentViewModel>.value(
                  value: attach,
                ),
              ],
              child: const ChatPage(),
            ),
          ),
        );
        await deliver(tester, h.ch, _request('completed-old'));
        await deliver(
          tester,
          h.ch,
          const ExtensionUiRequest(
            id: 'completed-old',
            method: ExtensionUiMethod.notify,
          ),
        );
        await deliver(tester, h.ch, _request('pending-old'));
        await deliver(
          tester,
          h.ch,
          const ExtensionUiRequest(
            id: 'pending-old',
            method: ExtensionUiMethod.notify,
            notifyType: 'warning',
            message: 'Try again',
          ),
        );
        expect(find.text('Completed'), findsOneWidget);
        expect(find.text('Try again'), findsOneWidget);
        // Production callback used after the New session action succeeds.
        late ChatReady state;
        await tester.runAsync(() async {
          final reset = h.vm.clearActiveSession();
          state = h.vm.state as ChatReady;
          await reset;
        });
        expect(state.uiFlows, isEmpty);
        expect(state.pendingUiRequest, isNull);
        expect(state.pendingUiError, isNull);
        expect(state.pendingUiErrorRevision, 0);
        await tester.pump();
        expect(find.byType(ExtensionUiCard), findsNothing);
        expect(find.text('Nothing here'), findsOneWidget);
        h.ch.sent.clear();
        for (final id in ['completed-old', 'pending-old']) {
          await h.vm.respondExtensionUi(
            ExtensionUiResponse(
              id: id,
              cancelled: true,
              ask: AskResponseEnrichmentWire(flowId: id, isCancel: true),
            ),
          );
          await deliver(
            tester,
            h.ch,
            ExtensionUiRequest(
              id: id,
              method: ExtensionUiMethod.notify,
              notifyType: 'warning',
              message: 'Stale warning',
            ),
          );
        }
        expect(h.ch.sent.whereType<ExtensionUiResponse>(), isEmpty);
        expect(find.byType(ExtensionUiCard), findsNothing);
        await deliver(tester, h.ch, _request('fresh-flow'));
        expect(find.byType(ExtensionUiCard), findsOneWidget);
        expect(find.text('Try again'), findsNothing);
        expect(find.text('Stale warning'), findsNothing);
        await tester.tap(find.text('Alpha'));
        await tester.pump();
        await tester.tap(find.widgetWithText(FilledButton, 'Submit'));
        await tester.pump();
        expect(
          h.ch.sent.whereType<ExtensionUiResponse>().single.id,
          'fresh-flow',
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        h.vm.dispose();
        voice.dispose();
        attach.dispose();
        actions.dispose();
        h.sync.dispose();
        h.conn.dispose();
        h.prefs.dispose();
      }
    },
  );
}
