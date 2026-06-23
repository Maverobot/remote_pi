import 'dart:async';
import 'dart:io';

import 'package:app/data/local/boxes.dart';
import 'package:app/data/local/records/message_record.dart';
import 'package:app/data/repositories/session_read_repository.dart';
import 'package:app/data/sync/sync_service.dart';
import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/domain/session_state.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/chat/widgets/ask_user_prompt_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:integration_test/integration_test.dart';

class _FakeChannel implements IChannel {
  final _ctrl = StreamController<ServerMessage>.broadcast();
  final List<ClientMessage> sent = [];

  @override
  Stream<ServerMessage> get serverMessages => _ctrl.stream;

  @override
  Future<void> send(ClientMessage msg) async {
    sent.add(msg);
  }

  @override
  Future<void> close() => _ctrl.close();

  void push(ServerMessage msg) => _ctrl.add(msg);
}

class _FakeStorage extends PairingStorage {
  @override
  Future<List<PeerRecord>> listPeers() async => const [];
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('stale ask_user cancel error closes the Android prompt', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('rp_ask_user_integration_');
    await LocalBoxes.initForTest(dir.path);

    final channel = _FakeChannel();
    final conn = ConnectionManager(
      factory: (_, _) async => channel,
      storage: _FakeStorage(),
    );
    final sync = SyncService(conn, LocalBoxes());
    const epk = 'epk_integration_ask_user';
    conn.adopt(
      channel,
      const PeerRecord(
        remoteEpk: epk,
        sessionName: 'Pi',
        relayUrl: 'ws://localhost',
        pairedAt: '2026-01-01T00:00:00Z',
      ),
    );
    await sync.activate(epk, 'main');

    final read = SessionReadRepository(LocalBoxes());
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StreamBuilder<List<MessageRecord>>(
            stream: read.watchMessages(epk, 'main'),
            builder: (context, snapshot) {
              final ask = (snapshot.data ?? const <MessageRecord>[])
                  .where((r) => r.role == MsgRole.askUser)
                  .cast<MessageRecord?>()
                  .firstOrNull;
              if (ask == null) return const SizedBox.shrink();
              return AskUserPromptCard(
                prompt: ask.toChatMessage() as AskUserPromptMsg,
                onRespond: (id, selections, freeform, comment, cancelled) {
                  sync.respondAskUser(AskUserResponse.cancelled(id));
                },
              );
            },
          ),
        ),
      ),
    );

    channel.push(
      AskUserPrompt(
        id: 'ask-stale',
        question: 'Still pending?',
        context: '',
        options: const [],
        allowMultiple: false,
        allowFreeform: true,
        allowComment: false,
      ),
    );
    await _settle(tester);
    expect(find.text('Cancel'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await _settle(tester);
    expect(channel.sent.whereType<AskUserResponse>().single.cancelled, isTrue);

    channel.push(
      ErrorMessage(
        inReplyTo: 'ask-stale',
        code: 'invalid_message',
        message: 'No pending ask_user prompt for id ask-stale',
      ),
    );
    await _settle(tester);

    expect(find.text('Cancel'), findsNothing);

    sync.dispose();
    conn.dispose();
    await Hive.close();
    await dir.delete(recursive: true);
  });

  testWidgets('same-session history omission removes stale ask_user prompt', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('rp_ask_user_omitted_');
    await LocalBoxes.initForTest(dir.path);

    final channel = _FakeChannel();
    final conn = ConnectionManager(
      factory: (_, _) async => channel,
      storage: _FakeStorage(),
    );
    final sync = SyncService(conn, LocalBoxes());
    const epk = 'epk_integration_ask_user_omitted';
    conn.adopt(
      channel,
      const PeerRecord(
        remoteEpk: epk,
        sessionName: 'Pi',
        relayUrl: 'ws://localhost',
        pairedAt: '2026-01-01T00:00:00Z',
      ),
    );
    await sync.activate(epk, 'main');

    final read = SessionReadRepository(LocalBoxes());
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StreamBuilder<List<MessageRecord>>(
            stream: read.watchMessages(epk, 'main'),
            builder: (context, snapshot) {
              final ask = (snapshot.data ?? const <MessageRecord>[])
                  .where((r) => r.role == MsgRole.askUser)
                  .cast<MessageRecord?>()
                  .firstOrNull;
              if (ask == null) return const SizedBox.shrink();
              return AskUserPromptCard(
                prompt: ask.toChatMessage() as AskUserPromptMsg,
                onRespond: (_, _, _, _, _) {},
              );
            },
          ),
        ),
      ),
    );

    channel.push(
      AskUserPrompt(
        id: 'ask-omitted',
        question: 'Should disappear?',
        context: '',
        options: const [],
        allowMultiple: false,
        allowFreeform: true,
        allowComment: false,
      ),
    );
    await _settle(tester);
    expect(find.text('Cancel'), findsOneWidget);

    channel.push(
      SessionHistory(
        inReplyTo: 'sync-after-answer',
        sessionStartedAt: 0,
        eos: true,
        events: const [UserInputEvt(ts: 1, id: 'u1', text: 'newer history')],
      ),
    );
    await _settle(tester);

    expect(find.text('Cancel'), findsNothing);

    sync.dispose();
    conn.dispose();
    await Hive.close();
    await dir.delete(recursive: true);
  });
}
