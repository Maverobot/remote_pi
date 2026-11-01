import 'dart:async';
import 'dart:io';

import 'package:app/data/local/boxes.dart';
import 'package:app/data/local/records/message_record.dart';
import 'package:app/data/sync/sync_service.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/protocol/protocol.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import '../../ui/chat/extension_ui_test_support.dart';

class _Wire extends ExtensionUiTestChannel {
  final _queries = <SessionSync>[];
  Completer<SessionSync>? _waiting;
  @override
  Future<void> send(ClientMessage message) async {
    await super.send(message);
    if (message is SessionSync) {
      final waiting = _waiting;
      if (waiting == null) {
        _queries.add(message);
      } else {
        _waiting = null;
        waiting.complete(message);
      }
    }
  }

  Future<SessionSync> nextQuery() {
    if (_queries.isNotEmpty) return Future.value(_queries.removeAt(0));
    return (_waiting = Completer<SessionSync>()).future;
  }
}

void main() {
  late Directory directory;
  setUpAll(() async {
    directory = Directory.systemTemp.createTempSync('sdk-full-test-');
    await LocalBoxes.initForTest(directory.path);
  });
  tearDownAll(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  Future<({_Wire wire, ConnectionManager conn, SyncService sync})>
  setup() async {
    final boxes = LocalBoxes();
    final box = await boxes.msgsBox(extensionUiTestPeer.remoteEpk, 'main');
    await box.clear();
    for (var i = 0; i < 35; i++) {
      await box.put(
        i,
        MessageRecord(
          id: 'old-$i',
          seq: i,
          role: MsgRole.user,
          text: 'cached $i',
          ts: DateTime.fromMillisecondsSinceEpoch(i),
        ).toJson(),
      );
    }
    final wire = _Wire();
    final conn = ConnectionManager(
      factory: (_, _) async => wire,
      storage: ExtensionUiTestStorage(),
      emitDebounce: Duration.zero,
    );
    final sync = SyncService(conn, boxes);
    await sync.activate(extensionUiTestPeer.remoteEpk, 'main');
    final online = conn.statusStream.firstWhere((s) => s is StatusOnline);
    conn.adopt(wire, extensionUiTestPeer);
    await online;
    sync.requestSync();
    return (wire: wire, conn: conn, sync: sync);
  }

  var marker = 0;
  Future<void> drain(_Wire wire) async {
    final id = 'sentinel-${++marker}';
    final box = await LocalBoxes().msgsBox(
      extensionUiTestPeer.remoteEpk,
      'main',
    );
    final written = box.watch().firstWhere(
      (e) => e.value is Map && (e.value as Map)['id'] == id,
    );
    wire.push(
      UserInput(
        id: id,
        text: id,
        streamingBehavior: UserMessageStreamingBehavior.steer,
      ),
    );
    await written;
  }

  Future<void> close(
    ({_Wire wire, ConnectionManager conn, SyncService sync}) h,
  ) async {
    final parked = LocalBoxes()
        .runtimeBox()
        .watch(key: '${extensionUiTestPeer.remoteEpk}:parking')
        .first;
    await h.sync.activate(extensionUiTestPeer.remoteEpk, 'parking');
    await parked;
    h.sync.dispose();
    h.conn.dispose();
    await h.wire.close();
  }

  Map<String, dynamic> part(
    String query,
    int index,
    bool eos,
    List<int> values, {
    String session = 'sdk',
    String room = 'main',
  }) => {
    'type': 'session_history',
    'in_reply_to': query,
    'room_id': room,
    'history_format': 'sdk_full',
    'session_id': session,
    'part': index,
    'session_started_at': 42,
    'eos': eos,
    'truncated': false,
    'events': [
      for (final i in values)
        {'type': 'user_input', 'id': 'sync_$i', 'text': 'message $i', 'ts': i},
    ],
  };

  test(
    'SDK snapshot preserves 35 cached rows until EOS, then replaces with all 40 without duplicates',
    () async {
      final h = await setup();
      try {
        final query = await h.wire.nextQuery();
        h.wire.push(
          ServerMessage.fromJson(
            part(query.id, 0, false, List.generate(35, (i) => i)),
          ),
        );
        await drain(h.wire);
        final box = await LocalBoxes().msgsBox(
          extensionUiTestPeer.remoteEpk,
          'main',
        );
        expect(
          box.values.where(
            (r) => (r as Map)['text'].toString().startsWith('cached '),
          ),
          hasLength(35),
        );
        // Normal end of Thinking/agent activity must not cancel the ordinary query.
        h.wire.push(AgentDone(inReplyTo: 'ended-turn'));
        final complete = LocalBoxes()
            .sessionsIndexBox()
            .watch(key: '${extensionUiTestPeer.remoteEpk}:main')
            .firstWhere(
              (e) =>
                  e.value is Map &&
                  (e.value as Map)['session_started_at'] == 42,
            );
        h.wire.push(
          ServerMessage.fromJson(
            part(query.id, 1, true, List.generate(5, (i) => i + 35)),
          ),
        );
        await complete;
        expect(box.values, hasLength(40));
        expect(box.values.last['text'], 'message 39');
        h.sync.requestSync();
        final repeated = await h.wire.nextQuery();
        h.wire.push(
          ServerMessage.fromJson(
            part(repeated.id, 0, true, List.generate(40, (i) => i)),
          ),
        );
        await drain(h.wire);
        expect(
          box.values.where(
            (r) => (r as Map)['text'].toString().startsWith('message '),
          ),
          hasLength(40),
        );
      } finally {
        await close(h);
      }
    },
  );

  test(
    'successful New clears normally and a late old snapshot cannot repopulate it',
    () async {
      final h = await setup();
      try {
        final old = await h.wire.nextQuery();
        h.wire.push(ServerMessage.fromJson(part(old.id, 0, false, [1])));
        await drain(h.wire);
        await h.sync.clearActiveSession();
        final box = await LocalBoxes().msgsBox(
          extensionUiTestPeer.remoteEpk,
          'main',
        );
        expect(box.values, isEmpty);
        h.wire.push(ServerMessage.fromJson(part(old.id, 1, true, [2])));
        await drain(h.wire);
        expect(
          box.values.any(
            (r) => (r as Map)['text'].toString().startsWith('message '),
          ),
          isFalse,
        );
        h.sync.requestSync();
        final fresh = await h.wire.nextQuery();
        final complete = LocalBoxes()
            .sessionsIndexBox()
            .watch(key: '${extensionUiTestPeer.remoteEpk}:main')
            .firstWhere(
              (e) =>
                  e.value is Map &&
                  (e.value as Map)['session_started_at'] == 42,
            );
        h.wire.push(
          ServerMessage.fromJson(
            part(fresh.id, 0, true, [9], session: 'new-sdk'),
          ),
        );
        await complete;
        expect(box.values.single['text'], 'message 9');
      } finally {
        await close(h);
      }
    },
  );

  for (final invalid in ['gap', 'session', 'truncated', 'legacy', 'room']) {
    test(
      'incomplete or invalid SDK snapshot ($invalid) preserves cached history',
      () async {
        final h = await setup();
        try {
          final query = await h.wire.nextQuery();
          h.wire.push(ServerMessage.fromJson(part(query.id, 0, false, [1])));
          final raw = part(
            query.id,
            invalid == 'gap' ? 2 : 1,
            true,
            [2],
            session: invalid == 'session' ? 'other-sdk' : 'sdk',
            room: invalid == 'room' ? 'other' : 'main',
          );
          if (invalid == 'truncated') raw['truncated'] = true;
          if (invalid == 'legacy') raw.remove('history_format');
          h.wire.push(ServerMessage.fromJson(raw));
          await drain(h.wire);
          final box = await LocalBoxes().msgsBox(
            extensionUiTestPeer.remoteEpk,
            'main',
          );
          expect(
            box.values.where(
              (r) => (r as Map)['text'].toString().startsWith('cached '),
            ),
            hasLength(35),
          );
        } finally {
          await close(h);
        }
      },
    );
  }
}
