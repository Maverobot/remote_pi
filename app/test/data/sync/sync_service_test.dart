// Plan/31 — SyncService is the single DB writer. Drives it through a fake
// channel adopted into a real ConnectionManager and asserts box contents.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:app/data/local/boxes.dart';
import 'package:app/data/local/records/message_record.dart';
import 'package:app/data/local/records/session_index_record.dart';
import 'package:app/data/repositories/session_read_repository.dart';
import 'package:app/data/sync/sync_service.dart';
import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/data/transport/peer_channel.dart';
import 'package:app/domain/session_state.dart';
import 'package:app/domain/thinking.dart';
import 'package:app/domain/background_progress.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/pairing/pair_request_flow.dart';
import 'package:app/protocol/protocol.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fake_async/fake_async.dart';
import 'package:hive/hive.dart';

import '../../fixtures/sdk_full_host.dart';

class _FakeChannel implements IChannel, IControlLink {
  final _ctrl = StreamController<ServerMessage>.broadcast();
  final _control = StreamController<ControlInbound>.broadcast();
  final List<ClientMessage> sent = [];
  String activeRoom = 'main';
  void Function()? requestHistory;
  Future<SessionSync>? historyQuery;
  @override
  Stream<ServerMessage> get serverMessages => _ctrl.stream;
  @override
  Stream<ControlInbound> get controlFrames => _control.stream;
  @override
  Future<void> send(ClientMessage msg) {
    final delivered = Future<void>.sync(() {
      sent.add(msg);
    });
    if (msg is SessionSync) historyQuery = delivered.then((_) => msg);
    return delivered;
  }

  @override
  void sendControl(Map<String, dynamic> json) {}

  void setActiveRoom(String roomId) {
    activeRoom = roomId;
  }

  @override
  Future<void> close() async {
    await _ctrl.close();
    await _control.close();
  }

  void push(ServerMessage m) {
    if (m is SessionHistory &&
        m.historyFormat == null &&
        !m.thinkingHistoryPresent &&
        !m.thinkingResetPending &&
        requestHistory != null) {
      requestHistory!();
      final query = historyQuery;
      if (query != null) {
        unawaited(
          query.then((request) => _ctrl.add(sdkFullHostReply(m, request.id))),
        );
        return;
      }
    }
    _ctrl.add(m);
  }

  void pushControl(ControlInbound m) => _control.add(m);
}

class _ThinkingBlockedBoxes extends LocalBoxes {
  Completer<void>? putRelease;
  Completer<void>? putStarted;
  void blockNextPut() {
    putRelease = Completer<void>();
    putStarted = Completer<void>();
  }

  Completer<void>? release;
  Completer<void>? started;
  void blockNextRead() {
    release = Completer<void>();
    started = Completer<void>();
  }

  @override
  Future<Box<dynamic>> msgsBox(String epk, String roomId) async {
    final pending = release;
    if (pending != null && !started!.isCompleted) {
      started!.complete();
      await pending.future;
    }
    return _ThinkingPutBox(await super.msgsBox(epk, roomId), this);
  }
}

// A deterministic public storage await, without calling SyncService internals.
class _ThinkingPutBox implements Box<dynamic> {
  final Box<dynamic> box;
  final _ThinkingBlockedBoxes barriers;
  _ThinkingPutBox(this.box, this.barriers);
  @override
  Iterable<dynamic> get keys => box.keys;
  @override
  Iterable<dynamic> get values => box.values;
  @override
  dynamic get(dynamic key, {dynamic defaultValue}) =>
      box.get(key, defaultValue: defaultValue);
  @override
  Future<void> put(dynamic key, dynamic value) async {
    if (barriers.putRelease != null && !barriers.putStarted!.isCompleted) {
      barriers.putStarted!.complete();
      await barriers.putRelease!.future;
    }
    await box.put(key, value);
  }

  @override
  Future<void> delete(dynamic key) => box.delete(key);
  @override
  Future<int> clear() => box.clear();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ByteTransport implements PeerTransport {
  final incoming = StreamController<Uint8List>();
  late final reader = StreamIterator(incoming.stream);
  final sent = <Map<String, dynamic>>[];
  @override
  Future<void> send(Uint8List bytes) async =>
      sent.add(jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>);
  @override
  Future<Uint8List> receive() async {
    if (await reader.moveNext()) return reader.current;
    throw StateError('closed');
  }

  @override
  Future<void> close() => incoming.close();
  void push(Map<String, dynamic> message) =>
      incoming.add(Uint8List.fromList(utf8.encode(jsonEncode(message))));
}

// Real in-memory Hive boxes let deferred storage and renewal timers run on the
// same virtual clock, without disk timing or wall-clock sleeps in lifecycle tests.
class _DeferredLocalBoxes extends LocalBoxes {
  final Box<dynamic> messages;
  final Box<dynamic> index;
  final Box<dynamic> runtime;
  _DeferredLocalBoxes(this.messages, this.index, this.runtime);

  Completer<void>? _readStarted;
  Completer<void>? _readRelease;
  ({Future<void> started, Completer<void> release}) deferMessages() {
    final started = _readStarted = Completer<void>();
    final release = _readRelease = Completer<void>();
    return (started: started.future, release: release);
  }

  @override
  Future<Box<dynamic>> msgsBox(String epk, String roomId) async {
    final release = _readRelease;
    if (release != null) {
      _readRelease = null;
      _readStarted!.complete();
      await release.future;
    }
    return messages;
  }

  @override
  Box<dynamic> sessionsIndexBox() => index;
  @override
  Box<dynamic> runtimeBox() => runtime;
}

class _FakeStorage extends PairingStorage {
  @override
  Future<List<PeerRecord>> listPeers() async => const [];
}

int _counter = 0;

late Directory _dir;

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 30));

void main() {
  setUpAll(() async {
    _dir = Directory.systemTemp.createTempSync('rp_v2_sync_');
    await LocalBoxes.initForTest(_dir.path);
  });
  tearDownAll(() async {
    await Hive.close();
    await _dir.delete(recursive: true);
  });

  Future<
    ({ConnectionManager conn, _FakeChannel ch, SyncService sync, String epk})
  >
  setup({
    Duration pendingSendTimeout = const Duration(seconds: 20),
    LocalBoxes? localBoxes,
  }) async {
    final ch = _FakeChannel();
    final conn = ConnectionManager(
      factory: (_, _) async => ch,
      storage: _FakeStorage(),
      emitDebounce: Duration.zero,
    );
    final boxes = localBoxes ?? LocalBoxes();
    final sync = SyncService(
      conn,
      boxes,
      pendingSendTimeout: pendingSendTimeout,
    );
    ch.requestHistory = sync.requestSync;
    final epk = 'epk_sync_${++_counter}';
    conn.adopt(
      ch,
      PeerRecord(
        remoteEpk: epk,
        sessionName: 'Pi',
        relayUrl: 'ws://localhost',
        pairedAt: '2026-01-01T00:00:00Z',
      ),
    );
    await _settle(); // _onlineActivated → activate(epk) settles
    return (conn: conn, ch: ch, sync: sync, epk: epk);
  }

  List<MessageRecord> messages(String epk, [String room = 'main']) {
    final box = LocalBoxes().openMsgsBox(epk, room);
    final out = [
      for (final v in box.values)
        MessageRecord.fromJson((v as Map).cast<String, dynamic>()),
    ];
    out.sort((a, b) => a.seq.compareTo(b.seq));
    return out;
  }

  SessionIndexRecord? index(String epk) {
    final raw = LocalBoxes().sessionsIndexBox().get('$epk:main');
    return raw is Map
        ? SessionIndexRecord.fromJson(raw.cast<String, dynamic>())
        : null;
  }

  String interest(_FakeChannel channel) => channel.sent
      .whereType<Ping>()
      .lastWhere((ping) => ping.backgroundProgress)
      .id;

  Pong progress(
    String token, {
    String session = 'parent',
    bool available = true,
    bool empty = false,
  }) => Pong(
    inReplyTo: token,
    backgroundProgress: BackgroundProgressMessage(
      inReplyTo: token,
      sessionId: session,
      epoch: 'epoch',
      available: available,
      groups: empty
          ? []
          : [
              BackgroundGroup(
                id: 'dispatch',
                label: 'Dispatch',
                tasks: [
                  const BackgroundTask(
                    id: 'worker',
                    label: 'Worker',
                    state: BackgroundTaskState.running,
                    elapsed: Duration(seconds: 5),
                  ),
                ],
              ),
            ],
    ),
  );

  for (final clearing in [false, true]) {
    for (final disposed in [false, true]) {
      test(
        'deferred ${clearing ? 'session clearing' : 'activation'} respects disposal=$disposed',
        () async {
          final epk = 'deferred_${++_counter}';
          final boxes = _DeferredLocalBoxes(
            await Hive.openBox<dynamic>('${epk}_messages', bytes: Uint8List(0)),
            await Hive.openBox<dynamic>('${epk}_index', bytes: Uint8List(0)),
            await Hive.openBox<dynamic>('${epk}_runtime', bytes: Uint8List(0)),
          );
          fakeAsync((clock) {
            final ch = _FakeChannel();
            final conn = ConnectionManager(
              factory: (_, _) async => ch,
              storage: _FakeStorage(),
              emitDebounce: Duration.zero,
            );
            conn.adopt(
              ch,
              PeerRecord(
                remoteEpk: epk,
                sessionName: 'Pi',
                relayUrl: 'ws://localhost',
                pairedAt: '2026-01-01',
              ),
            );
            clock.flushMicrotasks();
            // Defer the initial read, or let activation finish before deferring
            // the next session-clear read. No storage callback finishes by chance.
            var blocked = clearing ? null : boxes.deferMessages();
            final sync = SyncService(conn, boxes);
            try {
              clock.flushMicrotasks();
              var clearCompleted = false;
              if (clearing) {
                clock.elapse(const Duration(seconds: 1));
                ch.push(progress(interest(ch)));
                clock.flushMicrotasks();
                expect(sync.backgroundProgress?.observedCount, 1);
                blocked = boxes.deferMessages();
                sync.clearActiveSession().then((_) => clearCompleted = true);
              }
              var readStarted = false;
              blocked!.started.then((_) => readStarted = true);
              clock.flushMicrotasks();
              expect(readStarted, isTrue);
              final before = List<ClientMessage>.of(ch.sent);
              final histories = ch.sent.whereType<SessionSync>().length;
              if (disposed) sync.dispose();
              blocked.release.complete();
              clock.flushMicrotasks();
              if (clearing) expect(clearCompleted, isTrue);
              clock.elapse(const Duration(seconds: 1));
              expect(conn.status, isA<StatusOnline>());
              if (disposed) {
                expect(ch.sent, before);
                // Explicit requests must remain harmless too, even with a live
                // connection and the old activation/session clear now completed.
                sync.requestSync();
                expect(ch.sent, before);
              } else {
                expect(ch.sent.whereType<SessionSync>().length, histories + 1);
                ch.push(progress(interest(ch)));
                clock.flushMicrotasks();
                expect(
                  sync.backgroundProgress?.freshness,
                  BackgroundFreshness.fresh,
                );
              }
              final afterCompletion = List<ClientMessage>.of(ch.sent);
              clock.elapse(const Duration(seconds: 10));
              if (disposed) {
                expect(ch.sent, before);
              } else {
                expect(ch.sent.whereType<SessionSync>().length, histories + 1);
                final renewals = ch.sent
                    .skip(afterCompletion.length)
                    .whereType<Ping>()
                    .toList();
                expect(renewals, hasLength(2));
                expect(
                  renewals.every(
                    (ping) =>
                        ping.backgroundProgress && ping.id == interest(ch),
                  ),
                  isTrue,
                );
              }
            } finally {
              sync.dispose();
              conn.dispose();
              clock.flushMicrotasks();
            }
          });
        },
      );
    }
  }

  Pong thought({
    int revision = 1,
    String text = 'Received summary',
    String status = 'streaming',
    String session = 'S',
    String epoch = 'E',
    String room = 'main',
  }) =>
      ServerMessage.fromJson({
            'type': 'pong',
            'in_reply_to': 'thinking:m',
            'thinking': {
              'session_id': session,
              'epoch': epoch,
              'room_id': room,
              'message_id': 'm',
              'revision': revision,
              'status': status,
              'text': text,
              'ts': 1,
              'run_id': 'u',
            },
          })
          as Pong;

  SessionHistory thinkingHistory(
    String id, {
    int count = 1,
    String session = 'S',
    String epoch = 'E',
    List<Map<String, Object>> events = const [],
    Object? manifestOverride,
  }) =>
      ServerMessage.fromJson({
            'type': 'session_history',
            'in_reply_to': id,
            if (manifestOverride is! Map ||
                manifestOverride['kind'] != 'reset') ...{
              'history_format': 'sdk_full',
              'session_id': session,
              'part': 0,
            },
            'room_id': 'main',
            'session_started_at': 1,
            'events': events,
            'eos': true,
            'truncated': false,
            'thinking_history':
                manifestOverride ??
                {
                  'kind': 'reply',
                  'session_id': session,
                  'epoch': epoch,
                  'count': count,
                  'truncated': false,
                },
          })
          as SessionHistory;

  Pong supplement(
    String reply, {
    String message = 'm',
    int index = 0,
    int before = 0,
    int revision = 1,
    String text = 'history thought',
    String status = 'complete',
    String epoch = 'E',
  }) => Pong.fromJson({
    'in_reply_to': reply,
    'thinking': {
      ...thought(
        revision: revision,
        text: text,
        status: status,
        epoch: epoch,
      ).thinking!.toJson(),
      'message_id': message,
      'history': {'index': index, 'before_event': before},
    },
  });

  for (final anchoredHistory in [false, true]) {
    test(
      'thinking live position: distinct new live follows older answer, anchored history=$anchoredHistory',
      () async {
        final boxes = _ThinkingBlockedBoxes();
        final h = await setup(localBoxes: boxes);
        try {
          h.ch.push(UserInput(id: 'old-user', text: 'old user'));
          h.ch.push(AgentMessage(inReplyTo: 'old-answer', text: 'old answer'));
          await _settle();
          h.sync.requestSync();
          final id = h.ch.sent.whereType<SessionSync>().last.id;
          boxes.blockNextRead();
          h.ch.push(
            thinkingHistory(
              id,
              count: anchoredHistory ? 1 : 0,
              events: [
                {
                  'type': 'user_input',
                  'ts': 1,
                  'id': 'old-user',
                  'text': 'old user',
                },
                {
                  'type': 'agent_message',
                  'ts': 2,
                  'in_reply_to': 'old-answer',
                  'text': 'old answer',
                },
              ],
            ),
          );
          if (anchoredHistory) {
            h.ch.push(
              supplement(
                id,
                message: 'historical',
                before: 1,
                text: 'historical thinking',
              ),
            );
          }
          await boxes.started!.future;
          h.ch.push(
            Pong.fromJson({
              'in_reply_to': 'thinking:new-live',
              'thinking': {
                ...thought(text: 'new thinking').thinking!.toJson(),
                'message_id': 'new-live',
                'ts': 3,
              },
            }),
          );
          await _settle();
          boxes.release!.complete();
          await Future<void>.delayed(const Duration(milliseconds: 240));
          expect(messages(h.epk).map((r) => r.thinking?.text ?? r.text), [
            'old user',
            if (anchoredHistory) 'historical thinking',
            'old answer',
            'new thinking',
          ]);
          h.sync.leaveThinking(h.epk, 'main');
          await _settle();
          expect(messages(h.epk).last.thinking!.locallyInterrupted, isTrue);
          expect(messages(h.epk).map((r) => r.thinking?.text ?? r.text), [
            'old user',
            if (anchoredHistory) 'historical thinking',
            'old answer',
            'new thinking',
          ]);
        } finally {
          if (boxes.release != null && !boxes.release!.isCompleted) {
            boxes.release!.complete();
          }
          h.sync.dispose();
          h.conn.dispose();
          await _settle();
        }
      },
    );
  }

  for (final conflictStatus in ['complete', 'streaming']) {
    test(
      'thinking tombstone restore: equal $conflictStatus replay keeps producer fields through leave and history',
      () async {
        final boxes = _ThinkingBlockedBoxes()..blockNextRead();
        final h = await setup(localBoxes: boxes);
        try {
          await boxes.started!.future;
          final box = await LocalBoxes().msgsBox(h.epk, 'main');
          final tombstone = thought(
            revision: 3,
            text: '',
            status: 'complete',
          ).thinking!.observation;
          await box.put(
            0,
            MessageRecord(
              id: tombstone.id,
              seq: 0,
              role: MsgRole.assistant,
              ts: DateTime.fromMillisecondsSinceEpoch(1),
              thinking: tombstone,
            ).toJson(),
          );
          final checkpoint = SessionIndexRecord(
            epk: h.epk,
            roomId: 'main',
            thinkingScope: tombstone.scope,
          );
          await boxes.sessionsIndexBox().put(
            checkpoint.key,
            checkpoint.toJson(),
          );
          h.sync.requestSync();
          h.ch.push(
            thinkingHistory(h.ch.sent.whereType<SessionSync>().last.id),
          );
          await _settle();
          boxes.release!.complete();
          await _settle();
          h.ch.push(
            thought(
              revision: 3,
              text: 'conflicting replay',
              status: conflictStatus,
            ),
          );
          await Future<void>.delayed(const Duration(milliseconds: 240));
          expect(messages(h.epk).single.thinking, tombstone);
          h.sync.leaveThinking(h.epk, 'main');
          await _settle();
          expect(
            messages(h.epk).single.thinking,
            tombstone,
            reason:
                'authoritative complete tombstone must not be interrupted by a poisoned streaming cache',
          );
          h.sync.requestSync();
          final id = h.ch.sent.whereType<SessionSync>().last.id;
          h.ch.push(thinkingHistory(id));
          h.ch.push(
            supplement(
              id,
              revision: 3,
              text: 'conflicting historical replay',
              status: 'streaming',
            ),
          );
          await _settle();
          h.sync.leaveThinking(h.epk, 'main');
          await _settle();
          expect(messages(h.epk).single.thinking, tombstone);
          h.ch.push(thought(revision: 4, text: 'newer live'));
          await Future<void>.delayed(const Duration(milliseconds: 240));
          expect(
            messages(h.epk).single.thinking,
            thought(revision: 4, text: 'newer live').thinking!.observation,
          );
        } finally {
          if (!boxes.release!.isCompleted) boxes.release!.complete();
          h.sync.dispose();
          h.conn.dispose();
          await _settle();
        }
      },
    );
  }

  for (final replaceCheckpoint in [false, true]) {
    test(
      'thinking reset restore: captures original checkpoint before switching, replacement=$replaceCheckpoint',
      () async {
        final boxes = _ThinkingBlockedBoxes()..blockNextRead();
        final h = await setup(localBoxes: boxes);
        try {
          await boxes.started!.future;
          final original = await LocalBoxes().msgsBox(h.epk, 'main');
          final other = await LocalBoxes().msgsBox(h.epk, 'other');
          final retired = thought(status: 'complete').thinking!.observation;
          final replacement = thought(
            session: 'new-sdk',
            status: 'complete',
          ).thinking!.observation;
          final destination = thought(
            session: 'destination',
            room: 'other',
            status: 'complete',
          ).thinking!.observation;
          MessageRecord row(ThinkingObservation observation, int seq) =>
              MessageRecord(
                id: observation.id,
                seq: seq,
                role: MsgRole.assistant,
                ts: DateTime.fromMillisecondsSinceEpoch(1),
                thinking: observation,
              );
          final ordinary = MessageRecord(
            id: 'ordinary',
            seq: 7,
            role: MsgRole.user,
            text: 'keep original',
            ts: DateTime.fromMillisecondsSinceEpoch(1),
          ).toJson();
          await original.put(0, row(retired, 0).toJson());
          await original.put(7, ordinary);
          await other.put(0, row(destination, 0).toJson());
          await other.put(7, ordinary);
          final destinationBefore = other.toMap();
          final checkpoint = SessionIndexRecord(
            epk: h.epk,
            roomId: 'main',
            displayName: 'keep name',
            lastMessagePreview: 'keep preview',
            thinkingScope: retired.scope,
          );
          final indexBox = boxes.sessionsIndexBox();
          await indexBox.put(checkpoint.key, checkpoint.toJson());
          final destinationIndex = SessionIndexRecord(
            epk: h.epk,
            roomId: 'other',
            displayName: 'destination',
            thinkingScope: destination.scope,
          );
          await indexBox.put(destinationIndex.key, destinationIndex.toJson());
          h.ch.push(
            ServerMessage.fromJson({
              'type': 'session_history',
              'in_reply_to': 'other-owner-reset',
              'room_id': 'main',
              'session_started_at': 9,
              'events': [],
              'eos': true,
              'truncated': false,
              'thinking_reset_pending': true,
            }),
          );
          await _settle();
          final switching = h.sync.activate(h.epk, 'other');
          // Durable scope may advance after reset acceptance but before its queued cleanup.
          if (replaceCheckpoint) {
            await original.put(8, row(replacement, 8).toJson());
            await indexBox.put(
              checkpoint.key,
              checkpoint.copyWith(thinkingScope: replacement.scope).toJson(),
            );
          }
          boxes.release!.complete();
          await switching;
          await _settle();
          expect(original.get(0), isNull);
          expect(original.get(7), ordinary);
          expect(
            messages(h.epk)
                .where((r) => r.thinking != null)
                .map((r) => r.thinking!.scope.sessionId),
            replaceCheckpoint ? ['new-sdk'] : isEmpty,
          );
          expect(
            index(h.epk),
            replaceCheckpoint
                ? checkpoint.copyWith(thinkingScope: replacement.scope)
                : checkpoint.copyWith(clearThinkingScope: true),
          );
          expect(other.toMap(), destinationBefore);
          expect(indexBox.get(destinationIndex.key), destinationIndex.toJson());
        } finally {
          if (!boxes.release!.isCompleted) boxes.release!.complete();
          h.sync.dispose();
          h.conn.dispose();
          await _settle();
        }
      },
    );
  }

  test(
    'thinking retirement: same SDK epochs survive and checkpoint stays in original destination across switch',
    () async {
      final boxes = _ThinkingBlockedBoxes();
      final h = await setup(localBoxes: boxes);
      try {
        h.ch.push(thought(status: 'complete'));
        await _settle();
        h.sync.requestSync();
        h.ch.push(
          thinkingHistory(
            h.ch.sent.whereType<SessionSync>().last.id,
            epoch: 'E2',
            count: 1,
          ),
        );
        await _settle();
        h.ch.push(thought(epoch: 'E2', text: 'second epoch'));
        await _settle();
        h.sync.leaveThinking(h.epk, 'main');
        await _settle();
        expect(messages(h.epk).map((r) => r.thinking!.scope.epoch).toSet(), {
          'E',
          'E2',
        });
        boxes.blockNextRead();
        h.ch.push(thought(epoch: 'E2', revision: 2, status: 'complete'));
        await boxes.started!.future;
        h.sync.requestSync();
        h.ch.push(
          thinkingHistory(
            h.ch.sent.whereType<SessionSync>().last.id,
            session: 'replacement',
            count: 0,
          ),
        );
        await _settle();
        final switching = h.sync.activate(h.epk, 'other');
        boxes.release!.complete();
        await switching;
        await _settle();
        expect(index(h.epk)!.thinkingScope!.sessionId, 'replacement');
        expect(messages(h.epk), isEmpty);
        expect(messages(h.epk, 'other'), isEmpty);
        final other = LocalBoxes().sessionsIndexBox().get(
          LocalBoxes.sessionKey(h.epk, 'other'),
        );
        expect(
          other == null ||
              SessionIndexRecord.fromJson(
                    (other as Map).cast<String, dynamic>(),
                  ).thinkingScope ==
                  null,
          isTrue,
        );
      } finally {
        if (boxes.release != null && !boxes.release!.isCompleted) {
          boxes.release!.complete();
        }
        h.sync.dispose();
        h.conn.dispose();
      }
    },
  );

  test(
    'thinking interruption: equal replay and higher historical streaming retain flag until newer live resumes',
    () async {
      final h = await setup();
      try {
        h.ch.push(thought());
        await _settle();
        h.sync.leaveThinking(h.epk, 'main');
        await _settle();
        Future<void> replay(int revision) async {
          h.sync.requestSync();
          final id = h.ch.sent.whereType<SessionSync>().last.id;
          h.ch.push(thinkingHistory(id));
          h.ch.push(supplement(id, revision: revision, status: 'streaming'));
          await _settle();
          expect(messages(h.epk).single.thinking!.locallyInterrupted, isTrue);
          expect(messages(h.epk).single.thinking!.revision, revision);
        }

        await replay(1);
        await replay(2);
        final changes = <BoxEvent>[];
        final watch = LocalBoxes()
            .openMsgsBox(h.epk, 'main')
            .watch()
            .listen(changes.add);
        await replay(2);
        expect(
          changes,
          isEmpty,
          reason: 'identical scoped replay remains write-free',
        );
        await watch.cancel();
        h.ch.push(thought(revision: 2));
        await _settle();
        expect(messages(h.epk).single.thinking!.locallyInterrupted, isTrue);
        h.ch.push(thought(revision: 3));
        await Future<void>.delayed(const Duration(milliseconds: 240));
        expect(messages(h.epk).single.thinking!.locallyInterrupted, isFalse);
      } finally {
        h.sync.dispose();
        h.conn.dispose();
        await _settle();
      }
    },
  );

  test(
    'thinking retirement: new SDK retires only thinking before supplements complete',
    () async {
      final h = await setup();
      try {
        h.ch.push(UserInput(id: 'ordinary', text: 'preserved'));
        h.ch.push(ToolRequest(toolCallId: 'tool', tool: 'read', args: {}));
        h.ch.push(Compaction(summary: 'recap', tokensBefore: 5, ts: 4));
        await _settle();
        final box = LocalBoxes().openMsgsBox(h.epk, 'main');
        await box.put(
          40,
          MessageRecord(
            id: 'archived',
            seq: 40,
            role: MsgRole.askUser,
            ts: DateTime.fromMillisecondsSinceEpoch(1),
          ).toJson(),
        );
        h.ch.push(thought(status: 'complete'));
        await _settle();
        final ordinary = {
          for (final key in box.keys)
            if (MessageRecord.fromJson(
                  (box.get(key) as Map).cast<String, dynamic>(),
                ).thinking ==
                null)
              key: jsonEncode(box.get(key)),
        };
        h.sync.requestSync();
        h.ch.push(
          thinkingHistory(
            h.ch.sent.whereType<SessionSync>().last.id,
            session: 'new-SDK',
            count: 1,
          ),
        );
        await _settle();
        expect(
          messages(h.epk).where((r) => r.thinking != null),
          isEmpty,
          reason: 'retirement must not await optional supplements',
        );
        h.ch.push(thought(session: 'new-SDK', status: 'complete'));
        await _settle();
        expect(
          messages(
            h.epk,
          ).where((r) => r.thinking != null).single.thinking!.scope.sessionId,
          'new-SDK',
        );
        expect({
          for (final key in box.keys)
            if (MessageRecord.fromJson(
                  (box.get(key) as Map).cast<String, dynamic>(),
                ).thinking ==
                null)
              key: jsonEncode(box.get(key)),
        }, ordinary);
      } finally {
        h.sync.dispose();
        h.conn.dispose();
        await _settle();
      }
    },
  );

  for (final scenario in [
    'assembly leave',
    'queued switch',
    'writing dispose',
    'writing leave',
  ]) {
    test(
      'thinking interruption: $scenario retains historical partial in original position',
      () async {
        final boxes = _ThinkingBlockedBoxes();
        final h = await setup(localBoxes: boxes);
        try {
          h.sync.requestSync();
          final id = h.ch.sent.whereType<SessionSync>().last.id;
          h.ch.push(
            thinkingHistory(
              id,
              count: scenario == 'assembly leave' ? 2 : 1,
              events: [
                {
                  'type': 'user_input',
                  'ts': 0,
                  'id': 'before',
                  'text': 'before',
                },
                {
                  'type': 'agent_message',
                  'ts': 2,
                  'in_reply_to': 'after',
                  'text': 'after',
                },
              ],
            ),
          );
          await _settle();
          if (scenario == 'queued switch') boxes.blockNextRead();
          if (scenario.startsWith('writing')) boxes.blockNextPut();
          h.ch.push(
            supplement(
              id,
              status: 'streaming',
              text: 'received partial',
              before: 1,
            ),
          );
          if (scenario == 'queued switch') {
            await boxes.started!.future;
          } else if (scenario.startsWith('writing')) {
            await boxes.putStarted!.future;
          } else {
            await _settle();
          }
          Future<void>? switching;
          if (scenario == 'queued switch') {
            switching = h.sync.activate(h.epk, 'other');
          } else if (scenario == 'writing dispose') {
            h.sync.dispose();
          } else {
            h.sync.leaveThinking(h.epk, 'main');
          }
          if (scenario == 'queued switch') boxes.release!.complete();
          if (scenario.startsWith('writing')) boxes.putRelease!.complete();
          await switching;
          // Leave must close a partial assembly promptly, not wait three seconds.
          await _settle();
          final rows = messages(h.epk);
          expect(rows.map((r) => r.thinking?.text ?? r.text), [
            'before',
            'received partial',
            'after',
          ]);
          final observation = rows[1].thinking!;
          expect(observation.status, ThinkingStatus.streaming);
          expect(observation.revision, 1);
          expect(observation.locallyInterrupted, isTrue);
          if (scenario == 'queued switch') {
            expect(messages(h.epk, 'other'), isEmpty);
          }
        } finally {
          if (boxes.release != null && !boxes.release!.isCompleted) {
            boxes.release!.complete();
          }
          if (boxes.putRelease != null && !boxes.putRelease!.isCompleted) {
            boxes.putRelease!.complete();
          }
          h.sync.dispose();
          h.conn.dispose();
        }
      },
    );
  }

  for (final revision in [1, 2]) {
    test(
      'thinking loader: same-scope revision $revision history cannot erase interruption written by suspended restore',
      () async {
        final boxes = _ThinkingBlockedBoxes()..blockNextRead();
        final h = await setup(localBoxes: boxes);
        try {
          await boxes.started!.future;
          final box = await LocalBoxes().msgsBox(h.epk, 'main');
          final observation = thought().thinking!.observation;
          await box.put(
            0,
            MessageRecord(
              id: observation.id,
              seq: 0,
              role: MsgRole.assistant,
              ts: DateTime.fromMillisecondsSinceEpoch(1),
              thinking: observation,
            ).toJson(),
          );
          boxes.blockNextPut();
          boxes.release!.complete();
          await boxes.putStarted!.future;
          h.sync.requestSync();
          final id = h.ch.sent.whereType<SessionSync>().last.id;
          h.ch.push(thinkingHistory(id));
          h.ch.push(supplement(id, revision: revision, status: 'streaming'));
          await _settle();
          boxes.putRelease!.complete();
          await _settle();
          final restored = messages(h.epk).single.thinking!;
          expect(restored.revision, revision);
          expect(restored.status, ThinkingStatus.streaming);
          expect(restored.locallyInterrupted, isTrue);
          h.ch.push(thought(revision: revision + 1));
          await Future<void>.delayed(const Duration(milliseconds: 240));
          expect(messages(h.epk).single.thinking!.locallyInterrupted, isFalse);
        } finally {
          if (!boxes.release!.isCompleted) boxes.release!.complete();
          if (boxes.putRelease != null && !boxes.putRelease!.isCompleted) {
            boxes.putRelease!.complete();
          }
          h.sync.dispose();
          h.conn.dispose();
          await _settle();
        }
      },
    );
  }
  for (final boundary in ['empty read', 'stored read', 'row put']) {
    test(
      'thinking loader: newer scope wins across $boundary without starving ordinary readiness',
      () async {
        final boxes = _ThinkingBlockedBoxes()..blockNextRead();
        final h = await setup(localBoxes: boxes);
        try {
          await boxes.started!.future;
          await boxes.sessionsIndexBox().put(
            LocalBoxes.sessionKey(h.epk, 'main'),
            SessionIndexRecord(
              epk: h.epk,
              roomId: 'main',
              thinkingScope: const ThinkingScope(sessionId: 'S', epoch: 'E'),
            ).toJson(),
          );
          if (boundary != 'empty read') {
            final box = await LocalBoxes().msgsBox(h.epk, 'main');
            final observation = thought().thinking!.observation;
            await box.put(
              0,
              MessageRecord(
                id: observation.id,
                seq: 0,
                role: MsgRole.assistant,
                ts: DateTime.fromMillisecondsSinceEpoch(1),
                thinking: observation,
              ).toJson(),
            );
          }
          if (boundary == 'row put') {
            boxes.blockNextPut();
            boxes.release!.complete();
            await boxes.putStarted!.future;
          }
          h.sync.requestSync();
          final id = h.ch.sent.whereType<SessionSync>().last.id;
          h.ch.push(thinkingHistory(id, session: 'new-SDK', count: 0));
          await _settle();
          if (boundary == 'row put') {
            boxes.putRelease!.complete();
          } else {
            boxes.release!.complete();
          }
          await _settle();
          h.ch.push(
            thought(revision: 9, status: 'complete', text: 'stale SDK'),
          );
          h.ch.push(
            thought(
              session: 'new-SDK',
              status: 'complete',
              text: 'current SDK',
            ),
          );
          h.ch.push(
            AgentMessage(
              inReplyTo: 'ordinary-ready',
              text: 'ordinary still works',
            ),
          );
          await _settle();
          expect(
            messages(h.epk).any((r) => r.thinking?.text == 'stale SDK'),
            isFalse,
          );
          expect(
            messages(h.epk).any((r) => r.thinking?.text == 'current SDK'),
            isTrue,
          );
          expect(messages(h.epk).any((r) => r.id == 'ordinary-ready'), isTrue);
          expect(index(h.epk)!.thinkingScope!.sessionId, 'new-SDK');
        } finally {
          if (!boxes.release!.isCompleted) boxes.release!.complete();
          if (boxes.putRelease != null && !boxes.putRelease!.isCompleted) {
            boxes.putRelease!.complete();
          }
          h.sync.dispose();
          h.conn.dispose();
        }
      },
    );
  }

  for (final reset in [false, true]) {
    test(
      'thinking authority: queued history cannot republish after ${reset ? "SDK reset" : "explicit clear"}',
      () async {
        final boxes = _ThinkingBlockedBoxes();
        final h = await setup(localBoxes: boxes);
        try {
          h.ch.push(thought());
          h.sync.leaveThinking(h.epk, 'main');
          await Future<void>.delayed(const Duration(milliseconds: 240));
          h.sync.requestSync();
          final id = h.ch.sent.whereType<SessionSync>().last.id;
          boxes.blockNextRead();
          h.ch.push(thinkingHistory(id));
          h.ch.push(supplement(id, status: 'streaming'));
          await boxes.started!.future;
          Future<void>? clearing;
          if (reset) {
            h.ch.push(
              thinkingHistory(
                'reset',
                manifestOverride: {
                  'kind': 'reset',
                  'session_id': 'replacement',
                  'epoch': 'E2',
                  'count': 0,
                  'truncated': false,
                },
              ),
            );
            await _settle();
          } else {
            clearing = h.sync.clearActiveSession();
          }
          boxes.release!.complete();
          await clearing;
          await _settle();
          expect(messages(h.epk), isEmpty);
          h.sync.leaveThinking(h.epk, 'main');
          h.sync.dispose();
          await _settle();
          expect(
            messages(h.epk),
            isEmpty,
            reason: 'retired cache cannot create another original-box write',
          );
        } finally {
          if (boxes.release != null && !boxes.release!.isCompleted) {
            boxes.release!.complete();
          }
          h.sync.dispose();
          h.conn.dispose();
        }
      },
    );
  }

  test(
    'tagged foreign/malformed history is rejected before ordinary apply; legacy omission preserves thinking',
    () async {
      final h = await setup();
      h.ch.push(thought(status: 'complete'));
      h.ch.push(AgentMessage(inReplyTo: 'answer', text: 'ordinary'));
      await _settle();
      h.sync.requestSync();
      final id = h.ch.sent.whereType<SessionSync>().last.id;
      h.ch.push(thinkingHistory('other-phone', count: 0, session: 'foreign'));
      h.ch.push(
        thinkingHistory('other-phone', manifestOverride: {'bad': true}),
      );
      await _settle();
      expect(messages(h.epk).map((r) => r.id), contains('answer'));
      h.ch.push(thinkingHistory(id, manifestOverride: {'bad': true}));
      await _settle();
      expect(messages(h.epk).single.thinking!.text, 'Received summary');
      h.ch.push(
        SessionHistory(
          inReplyTo: 'legacy',
          sessionStartedAt: 1,
          events: const [],
          eos: true,
        ),
      );
      await _settle();
      expect(messages(h.epk).single.thinking!.text, 'Received summary');
      h.sync.dispose();
      h.conn.dispose();
    },
  );

  test(
    'history uses wire event anchors through tool-result collapse and preserves newer live revision',
    () async {
      final h = await setup();
      h.sync.requestSync();
      final id = h.ch.sent.whereType<SessionSync>().last.id;
      h.ch.push(supplement(id, before: 2)); // may precede the base
      h.ch.push(
        thinkingHistory(
          id,
          count: 2,
          events: [
            {
              'type': 'tool_request',
              'ts': 1,
              'tool_call_id': 'tool',
              'tool': 'read',
              'args': <String, Object>{},
            },
            {
              'type': 'tool_result',
              'ts': 2,
              'tool_call_id': 'tool',
              'result': 'done',
            },
            {
              'type': 'agent_message',
              'ts': 3,
              'in_reply_to': 'u',
              'text': 'answer',
            },
          ],
        ),
      );
      h.ch.push(thought(revision: 4, text: 'newer live', status: 'complete'));
      h.ch.push(
        supplement(
          id,
          message: 'second',
          index: 1,
          before: 2,
          text: 'second thought',
        ),
      );
      await _settle();
      final rows = messages(h.epk);
      expect(rows.map((r) => r.thinking?.text ?? r.text), [
        '',
        'newer live',
        'second thought',
        'answer',
      ]);
      expect(rows.first.tool!.result, 'done');
      expect(rows.map((r) => r.seq), [0, 1, 2, 3]);
      h.sync.requestSync();
      final replayId = h.ch.sent.whereType<SessionSync>().last.id;
      h.ch.push(thinkingHistory(replayId, count: 0, epoch: 'next-epoch'));
      await _settle();
      expect(messages(h.epk).where((r) => r.thinking != null).length, 2);
      h.sync.dispose();
      h.conn.dispose();
    },
  );

  test(
    'missing supplements fall back in bounded time without erasing received incomplete thought',
    () async {
      final h = await setup();
      h.ch.push(thought());
      await _settle();
      h.ch.push(Cancelled(inReplyTo: 'c', targetId: 'u'));
      await _settle();
      h.sync.requestSync();
      final id = h.ch.sent.whereType<SessionSync>().last.id;
      h.ch.push(
        thinkingHistory(
          id,
          count: 2,
          events: [
            {
              'type': 'agent_message',
              'ts': 2,
              'in_reply_to': 'a',
              'text': 'base answer',
            },
          ],
        ),
      );
      h.ch.push(
        supplement(id, revision: 1, status: 'streaming', text: 'old text'),
      );
      h.ch.push(
        supplement(id, index: 1, before: 99),
      ); // invalid anchor cannot complete
      await Future<void>.delayed(const Duration(milliseconds: 3100));
      expect(messages(h.epk).any((r) => r.text == 'base answer'), isTrue);
      final thinking = messages(
        h.epk,
      ).singleWhere((r) => r.thinking != null).thinking!;
      expect(thinking.text, 'Received summary');
      expect(thinking.locallyInterrupted, isTrue);
      h.ch.push(supplement(id, index: 1, message: 'late'));
      await _settle();
      expect(messages(h.epk).where((r) => r.thinking != null).length, 1);
      h.sync.dispose();
      h.conn.dispose();
    },
  );

  test(
    'daemon reset marker invalidates all-owner scope and queued thinking, malformed/foreign-room markers cannot',
    () async {
      final h = await setup();
      h.ch.push(thought());
      await _settle();
      final reset = <String, dynamic>{
        'type': 'session_history',
        'in_reply_to': 'another-owners-action',
        'room_id': 'main',
        'session_started_at': 9,
        'events': [],
        'eos': true,
        'truncated': false,
        'thinking_reset_pending': true,
      };
      h.ch.push(ServerMessage.fromJson({...reset, 'room_id': 'other'}));
      h.ch.push(
        ServerMessage.fromJson({...reset, 'thinking_reset_pending': 'true'}),
      );
      await _settle();
      expect(messages(h.epk).single.thinking, isNotNull);
      h.ch.push(ServerMessage.fromJson(reset));
      await _settle();
      h.ch.push(
        thought(revision: 5, status: 'complete', text: 'stale exiting SDK'),
      );
      await _settle();
      expect(messages(h.epk), isEmpty);
      final id = h.ch.sent.whereType<SessionSync>().last.id;
      h.ch.push(thinkingHistory(id, count: 0, session: 'actual-new-SDK'));
      await _settle();
      final index =
          LocalBoxes().sessionsIndexBox().get(
                LocalBoxes.sessionKey(h.epk, 'main'),
              )
              as Map;
      expect(
        SessionIndexRecord.fromJson(
          index.cast<String, dynamic>(),
        ).thinkingScope!.sessionId,
        'actual-new-SDK',
      );
      h.sync.dispose();
      final restored = SyncService(h.conn, LocalBoxes());
      await _settle();
      h.ch.push(thought(status: 'complete', session: 'S'));
      await _settle();
      expect(
        messages(h.epk),
        isEmpty,
      ); // zero-card checkpoint still fences old SDK
      restored.dispose();
      h.conn.dispose();
    },
  );

  test(
    'scoped tombstone wins stale history, identical replay is write-free and actual SDK reset retires it',
    () async {
      final h = await setup();
      h.ch.push(thought(revision: 3, text: '', status: 'complete'));
      await _settle();
      Future<void> replay() async {
        h.sync.requestSync();
        final id = h.ch.sent.whereType<SessionSync>().last.id;
        h.ch.push(thinkingHistory(id));
        h.ch.push(supplement(id, revision: 2, text: 'must not resurrect'));
        await _settle();
      }

      await replay();
      expect(messages(h.epk).single.thinking!.visible, isFalse);
      final changes = <BoxEvent>[];
      final subscription = LocalBoxes()
          .openMsgsBox(h.epk, 'main')
          .watch()
          .listen(changes.add);
      await replay();
      expect(changes, isEmpty);
      await subscription.cancel();
      final reset = <String, dynamic>{
        'type': 'session_history',
        'in_reply_to': 'global-reset',
        'room_id': 'main',
        'session_started_at': 2,
        'events': [],
        'eos': true,
        'truncated': false,
        'thinking_history': {
          'kind': 'reset',
          'session_id': 'new-SDK',
          'epoch': 'new-E',
          'count': 0,
          'truncated': false,
        },
      };
      h.ch.push(
        ServerMessage.fromJson({
          ...reset,
          'events': [
            {
              'type': 'agent_message',
              'in_reply_to': 'u',
              'text': 'noncanonical',
              'ts': 1,
            },
          ],
        }),
      );
      await _settle();
      expect(messages(h.epk).single.thinking!.scope.sessionId, 'S');
      h.ch.push(ServerMessage.fromJson(reset));
      await _settle();
      expect(messages(h.epk), isEmpty);
      h.ch.push(thought(revision: 9, status: 'complete'));
      await _settle();
      expect(messages(h.epk), isEmpty);
      h.sync.dispose();
      h.conn.dispose();
    },
  );

  test(
    'oversized optional history count falls back; stale old-channel reset cannot clear current thinking',
    () async {
      final h = await setup();
      h.ch.push(thought(status: 'complete'));
      await _settle();
      h.sync.requestSync();
      final id = h.ch.sent.whereType<SessionSync>().last.id;
      h.ch.push(
        thinkingHistory(
          id,
          count: 257,
          events: [
            {
              'type': 'agent_message',
              'in_reply_to': 'u',
              'text': 'base survives',
              'ts': 2,
            },
          ],
        ),
      );
      await _settle();
      expect(messages(h.epk).any((r) => r.text == 'base survives'), isTrue);
      expect(
        messages(h.epk).singleWhere((r) => r.thinking != null).thinking!.text,
        'Received summary',
      );
      final next = _FakeChannel();
      h.ch.push(
        ServerMessage.fromJson({
          'type': 'session_history',
          'in_reply_to': 'stale-reset',
          'room_id': 'main',
          'session_started_at': 99,
          'events': [],
          'eos': true,
          'truncated': false,
          'thinking_reset_pending': true,
        }),
      );
      h.conn.adopt(
        next,
        PeerRecord(
          remoteEpk: h.epk,
          sessionName: 'Pi',
          relayUrl: 'ws://localhost',
          pairedAt: '2026-01-01T00:00:00Z',
        ),
      );
      await _settle();
      expect(messages(h.epk).where((r) => r.thinking != null).length, 1);
      h.sync.dispose();
      h.conn.dispose();
    },
  );

  test(
    'explicit clear retires original thinking after queued write and switch without clearing ordinary history or new indexes',
    () async {
      final boxes = _ThinkingBlockedBoxes();
      final h = await setup(localBoxes: boxes);
      h.ch.push(
        AgentMessage(inReplyTo: 'ordinary', text: 'Keep old ordinary behavior'),
      );
      h.ch.push(thought());
      await _settle();
      final otherBox = await LocalBoxes().msgsBox(h.epk, 'other');
      await otherBox.put(
        0,
        MessageRecord(
          id: 'other-user',
          seq: 0,
          role: MsgRole.user,
          text: 'Other destination',
          ts: DateTime.fromMillisecondsSinceEpoch(1),
        ).toJson(),
      );
      final otherIndex = SessionIndexRecord(
        epk: h.epk,
        roomId: 'other',
        displayName: 'Other',
        thinkingScope: const ThinkingScope(
          sessionId: 'other-SDK',
          epoch: 'other-epoch',
        ),
      );
      await boxes.sessionsIndexBox().put(otherIndex.key, otherIndex.toJson());
      boxes.blockNextRead();
      h.sync.leaveThinking(h.epk, 'main');
      await boxes.started!.future;
      final clearing = h.sync.clearActiveSession();
      final switching = h.sync.activate(h.epk, 'other');
      boxes.release!.complete();
      await clearing;
      await switching;
      await _settle();
      expect(messages(h.epk).map((r) => r.text), [
        'Keep old ordinary behavior',
      ]);
      final oldIndex =
          boxes.sessionsIndexBox().get(LocalBoxes.sessionKey(h.epk, 'main'))
              as Map;
      expect(
        SessionIndexRecord.fromJson(
          oldIndex.cast<String, dynamic>(),
        ).thinkingScope,
        isNull,
      );
      expect(messages(h.epk, 'other').single.text, 'Other destination');
      expect(
        SessionIndexRecord.fromJson(
          (boxes.sessionsIndexBox().get(otherIndex.key) as Map)
              .cast<String, dynamic>(),
        ),
        otherIndex,
      );
      await Future<void>.delayed(const Duration(milliseconds: 220));
      expect(messages(h.epk).where((r) => r.thinking != null), isEmpty);
      h.sync.dispose();
      h.conn.dispose();
    },
  );

  test(
    'thinking cancellation retains partial text but ordinary stream is discarded',
    () async {
      final h = await setup();
      h.ch.push(AgentChunk(inReplyTo: 'u', delta: 'ordinary'));
      h.ch.push(thought());
      await _settle();
      h.ch.push(Cancelled(inReplyTo: 'cancel', targetId: 'u'));
      await _settle();
      final row = messages(h.epk).single;
      expect(row.text, isEmpty);
      expect(row.thinking!.text, 'Received summary');
      expect(row.thinking!.revision, 1);
      expect(row.thinking!.locallyInterrupted, isTrue);
      expect(h.sync.streaming, isNull);
      h.ch.push(
        thought(
          revision: 2,
          text: 'Final provider summary',
          status: 'complete',
        ),
      );
      await _settle();
      expect(messages(h.epk).single.thinking!.incomplete, isFalse);
      expect(messages(h.epk).single.thinking!.text, 'Final provider summary');
      h.sync.dispose();
      h.conn.dispose();
    },
  );

  test(
    'thinking tombstone survives stale replay and checkpoint protects restored scope',
    () async {
      final h = await setup();
      h.ch.push(thought(status: 'complete'));
      await _settle();
      h.ch.push(thought(revision: 3, text: '', status: 'complete'));
      h.ch.push(thought(revision: 2, text: 'stale', status: 'complete'));
      await _settle();
      expect(messages(h.epk).single.thinking!.visible, isFalse);
      expect(messages(h.epk).single.thinking!.revision, 3);
      h.sync.dispose();
      final restored = SyncService(h.conn, LocalBoxes());
      await _settle();
      h.ch.push(thought(session: 'foreign', status: 'complete'));
      await _settle();
      expect(messages(h.epk).single.thinking!.scope.sessionId, 'S');
      final raw =
          LocalBoxes().sessionsIndexBox().get(
                LocalBoxes.sessionKey(h.epk, 'main'),
              )
              as Map;
      expect(
        SessionIndexRecord.fromJson(raw.cast<String, dynamic>()).thinkingScope,
        const ThinkingScope(sessionId: 'S', epoch: 'E'),
      );
      restored.dispose();
      h.conn.dispose();
    },
  );

  test(
    'accepted coalesced thinking writes remain in original room across activation',
    () async {
      final h = await setup();
      h.ch.push(thought());
      await _settle();
      await h.sync.activate(h.epk, 'other');
      await _settle();
      expect(messages(h.epk).single.thinking!.text, 'Received summary');
      expect(messages(h.epk).single.thinking!.incomplete, isTrue);
      expect(messages(h.epk, 'other'), isEmpty);
      h.ch.push(thought(status: 'complete'));
      await _settle();
      expect(messages(h.epk, 'other'), isEmpty);
      h.sync.dispose();
      h.conn.dispose();
    },
  );

  test(
    'background launch completion cannot finish the observed worker; no task persistence',
    () async {
      final s = await setup();
      s.sync.requestSync();
      final token = interest(s.ch);
      s.ch.push(progress(token));
      s.ch.push(
        ToolResult(toolCallId: 'launch', result: 'Async launch returned'),
      );
      await _settle();
      expect(s.sync.backgroundProgress?.observedCount, 1);
      expect(messages(s.epk).where((m) => m.role != MsgRole.tool), isEmpty);
      s.ch.push(progress('other-parent-token', empty: true));
      await _settle();
      expect(s.sync.backgroundProgress?.observedCount, 1);
      s.ch.push(progress(token, empty: true));
      await _settle();
      expect(s.sync.backgroundProgress?.visible, isFalse);
      s.sync.dispose();
      s.conn.dispose();
    },
  );

  test(
    'background offline and unavailable freeze time; reconnect requires a fresh token',
    () async {
      final s = await setup();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      s.sync.requestSync();
      final token = interest(s.ch);
      s.ch.push(progress(token));
      await _settle();
      s.ch.push(progress(token, available: false));
      await _settle();
      final frozen =
          s.sync.backgroundProgress!.groups.single.tasks.single.elapsed;
      expect(
        s.sync.backgroundProgress!.freshness,
        BackgroundFreshness.unavailable,
      );
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      expect(
        s.sync.backgroundProgress!.groups.single.tasks.single.elapsed,
        frozen,
      );
      await s.conn.disconnect();
      await _settle();
      expect(s.sync.backgroundProgress!.freshness, BackgroundFreshness.offline);
      final fresh = _FakeChannel();
      s.conn.adopt(
        fresh,
        PeerRecord(
          remoteEpk: s.epk,
          sessionName: 'Pi',
          relayUrl: 'ws://localhost',
          pairedAt: '2026-01-01',
        ),
      );
      await _settle();
      s.sync.requestSync();
      expect(
        s.sync.backgroundProgress!.freshness,
        BackgroundFreshness.refreshing,
      );
      fresh.push(progress(token, empty: true));
      await _settle();
      expect(s.sync.backgroundProgress!.observedCount, 1);
      fresh.push(progress(interest(fresh)));
      await _settle();
      expect(s.sync.backgroundProgress!.freshness, BackgroundFreshness.fresh);
      s.sync.dispose();
      s.conn.dispose();
    },
  );

  test(
    'background room loss freezes progress while relay stays online',
    () async {
      final s = await setup();
      // Let the existing startup history-sync debounce finish before reconnecting.
      await Future<void>.delayed(const Duration(milliseconds: 250));
      s.ch.pushControl(
        RoomAnnounced(peer: s.epk, roomId: 'main', startedAt: 1),
      );
      await _settle();
      s.sync.requestSync();
      final token = interest(s.ch);
      s.ch.push(progress(token));
      await _settle();
      s.ch.pushControl(RoomEnded(peer: s.epk, roomId: 'main', sinceTs: 2));
      await _settle();
      expect(s.conn.status, isA<StatusOnline>());
      expect(s.sync.backgroundProgress?.freshness, BackgroundFreshness.offline);
      s.ch.push(progress(token, empty: true));
      await _settle();
      expect(s.sync.backgroundProgress?.observedCount, 1);
      s.ch.pushControl(
        RoomAnnounced(peer: s.epk, roomId: 'main', startedAt: 1),
      );
      await _settle();
      expect(
        s.sync.backgroundProgress?.freshness,
        BackgroundFreshness.refreshing,
      );
      s.ch.push(progress(interest(s.ch)));
      await _settle();
      expect(s.sync.backgroundProgress?.freshness, BackgroundFreshness.fresh);
      s.sync.dispose();
      s.conn.dispose();
    },
  );

  test(
    'background view cannot leak across rooms, parent replacement or new session',
    () async {
      final s = await setup();
      s.sync.requestSync();
      final token = interest(s.ch);
      s.ch.push(progress(token));
      await _settle();
      s.ch.push(progress(token, session: 'replacement', available: false));
      await _settle();
      expect(s.sync.backgroundProgress, isNull);
      s.ch.push(progress(token, session: 'replacement'));
      await _settle();
      s.conn.switchRoom('other-room');
      await s.sync.activate(s.epk, 'other-room');
      s.ch.push(progress(token));
      await _settle();
      expect(s.sync.backgroundProgress, isNull);
      s.sync.requestSync();
      s.ch.push(progress(interest(s.ch)));
      await _settle();
      expect(s.sync.backgroundProgress?.observedCount, 1);
      await s.sync.clearActiveSession();
      expect(s.sync.backgroundProgress, isNull);
      s.ch.push(progress(token));
      await _settle();
      expect(s.sync.backgroundProgress, isNull);
      s.sync.dispose();
      s.conn.dispose();
    },
  );

  test(
    'preannounced room loss and presence-only recovery freeze then renew independently of history',
    () async {
      final s = await setup();
      try {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        s.ch.pushControl(
          RoomAnnounced(peer: s.epk, roomId: 'main', startedAt: 1),
        );
        s.ch.pushControl(
          RoomAnnounced(peer: s.epk, roomId: 'preannounced', startedAt: 2),
        );
        await _settle();
        s.conn.switchRoom('preannounced');
        await _settle();
        await s.sync.activate(s.epk, 'preannounced');
        s.sync.requestSync();
        final token = interest(s.ch);
        s.ch.push(progress(token));
        await _settle();
        s.ch.pushControl(
          RoomEnded(peer: s.epk, roomId: 'preannounced', sinceTs: 3),
        );
        await _settle();
        expect(
          s.sync.backgroundProgress!.freshness,
          BackgroundFreshness.offline,
        );
        final frozen =
            s.sync.backgroundProgress!.groups.single.tasks.single.elapsed;
        s.ch.push(progress(token, empty: true));
        await Future<void>.delayed(const Duration(milliseconds: 1100));
        expect(
          s.sync.backgroundProgress!.groups.single.tasks.single.elapsed,
          frozen,
        );
        s.ch.pushControl(
          RoomAnnounced(peer: s.epk, roomId: 'preannounced', startedAt: 2),
        );
        await _settle();
        expect(interest(s.ch), isNot(token));
        s.ch.push(progress(interest(s.ch)));
        await _settle();
        s.ch.pushControl(PeerOffline(peer: s.epk, sinceTs: 4));
        await _settle();
        expect(
          s.sync.backgroundProgress!.freshness,
          BackgroundFreshness.offline,
        );
        final before = interest(s.ch);
        final histories = s.ch.sent.whereType<SessionSync>().length;
        s.ch.pushControl(PeerOnline(peer: s.epk));
        await _settle();
        expect(interest(s.ch), isNot(before));
        expect(s.ch.sent.whereType<SessionSync>().length, histories);
        expect(
          s.sync.backgroundProgress!.freshness,
          BackgroundFreshness.refreshing,
        );
        s.ch.push(progress(before, empty: true));
        await _settle();
        expect(s.sync.backgroundProgress!.observedCount, 1);
        s.ch.push(progress(interest(s.ch)));
        await _settle();
        expect(s.sync.backgroundProgress!.freshness, BackgroundFreshness.fresh);
      } finally {
        s.sync.dispose();
        s.conn.dispose();
      }
    },
  );

  test(
    'background renewal never replays history and silence expires freshness without finishing tasks',
    () async {
      final s = await setup();
      try {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        s.sync.requestSync();
        final token = interest(s.ch);
        final histories = s.ch.sent.whereType<SessionSync>().length;
        s.ch.push(progress(token));
        await _settle();
        await Future<void>.delayed(const Duration(milliseconds: 16100));
        final renewals = s.ch.sent.whereType<Ping>().where(
          (m) => m.backgroundProgress && m.id == token,
        );
        expect(renewals.length, greaterThanOrEqualTo(4));
        expect(s.ch.sent.whereType<SessionSync>().length, histories);
        expect(
          s.sync.backgroundProgress!.freshness,
          BackgroundFreshness.unavailable,
        );
        expect(
          s.sync.backgroundProgress!.groups.single.tasks.single.state,
          BackgroundTaskState.running,
        );
        final frozen =
            s.sync.backgroundProgress!.groups.single.tasks.single.elapsed;
        s.ch.pushControl(PeerOffline(peer: s.epk, sinceTs: 1));
        await _settle();
        final count = s.ch.sent
            .whereType<Ping>()
            .where((m) => m.backgroundProgress)
            .length;
        await Future<void>.delayed(const Duration(milliseconds: 5100));
        expect(
          s.ch.sent.whereType<Ping>().where((m) => m.backgroundProgress).length,
          count,
        );
        expect(
          s.sync.backgroundProgress!.groups.single.tasks.single.elapsed,
          frozen,
        );
      } finally {
        s.sync.dispose();
        s.conn.dispose();
      }
    },
  );

  test(
    'malformed current-token scope freezes through byte codec without adopting invalid identity',
    () async {
      final bytes = _ByteTransport();
      final channel = PlainPeerChannel(transport: bytes);
      final conn = ConnectionManager(
        factory: (_, _) async => channel,
        storage: _FakeStorage(),
      );
      final sync = SyncService(conn, LocalBoxes());
      try {
        conn.adopt(
          channel,
          PeerRecord(
            remoteEpk: 'byte_scope',
            sessionName: 'Pi',
            relayUrl: 'ws://localhost',
            pairedAt: '2026-01-01',
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 300));
        sync.requestSync();
        await _settle();
        final token = bytes.sent.lastWhere(
          (m) => m['background_progress'] == true,
        )['id'];
        final observation = <String, dynamic>{
          'session_id': 'parent',
          'epoch': 'epoch',
          'available': true,
          'truncated': false,
          'groups': [
            {
              'id': 'g',
              'tasks': [
                {
                  'id': 't',
                  'label': 'Worker',
                  'state': 'running',
                  'elapsed_ms': 5000,
                },
              ],
            },
          ],
        };
        void push(Object? payload, [Object? reply]) => bytes.push({
          'type': 'pong',
          'in_reply_to': reply ?? token,
          'background_progress': payload,
        });
        for (final field in ['session_id', 'epoch']) {
          for (final invalid in [null, '', 3, 'x' * 257]) {
            push(observation);
            await _settle();
            expect(
              sync.backgroundProgress!.freshness,
              BackgroundFreshness.fresh,
            );
            push({...observation, field: invalid}, 'another-phone');
            await _settle();
            expect(
              sync.backgroundProgress!.freshness,
              BackgroundFreshness.fresh,
            );
            push({...observation, field: invalid});
            await _settle();
            expect(
              sync.backgroundProgress!.freshness,
              BackgroundFreshness.unavailable,
            );
            expect(sync.backgroundProgress!.sessionId, 'parent');
            expect(sync.backgroundProgress!.epoch, 'epoch');
            expect(sync.backgroundProgress!.observedCount, 1);
          }
        }
        final frozen =
            sync.backgroundProgress!.groups.single.tasks.single.elapsed;
        await Future<void>.delayed(const Duration(milliseconds: 1100));
        expect(
          sync.backgroundProgress!.groups.single.tasks.single.elapsed,
          frozen,
        );
        push(observation);
        await _settle();
        expect(sync.backgroundProgress!.freshness, BackgroundFreshness.fresh);
        push({...observation, 'groups': []});
        await _settle();
        expect(sync.backgroundProgress!.visible, isFalse);
      } finally {
        sync.dispose();
        conn.dispose();
      }
    },
  );

  test(
    'user_message echo writes one MessageRecord + updates the index',
    () async {
      final s = await setup();
      s.ch.push(UserInput(id: 'u1', text: 'hi'));
      await _settle();

      final m = messages(s.epk);
      expect(m, hasLength(1));
      expect(m.first.role, MsgRole.user);
      expect(m.first.text, 'hi');
      expect(m.first.pending, isFalse);
      expect(index(s.epk)?.status, SessionActivity.working);
      s.conn.dispose();
      s.sync.dispose();
    },
  );

  test('optimistic send + echo dedupe → exactly one record', () async {
    final s = await setup();
    await s.sync.sendMessage('hello');
    await _settle();
    expect(messages(s.epk), hasLength(1));
    expect(messages(s.epk).first.pending, isTrue);

    final id = (s.ch.sent.whereType<UserMessage>().last).id;
    s.ch.push(UserInput(id: id, text: 'hello'));
    await _settle();

    final m = messages(s.epk);
    expect(m, hasLength(1), reason: 'echo dedupes by id — no duplicate');
    expect(m.first.pending, isFalse);
    s.conn.dispose();
    s.sync.dispose();
  });

  test(
    'steer send keeps active working target and sets streaming behavior on wire',
    () async {
      final s = await setup();
      s.ch.push(UserInput(id: 'u1', text: 'primary'));
      await _settle();

      await s.sync.sendMessage(
        'refine this',
        streamingBehavior: UserMessageStreamingBehavior.steer,
      );
      await _settle();

      final sent = s.ch.sent.whereType<UserMessage>().lastWhere(
        (m) => m.text == 'refine this',
      );
      expect(sent.streamingBehavior, UserMessageStreamingBehavior.steer);
      final steerRow = messages(s.epk).singleWhere((r) => r.id == sent.id);
      expect(steerRow.pending, isTrue);
      expect(steerRow.steering, isTrue);
      expect((steerRow.toChatMessage() as UserMsg).steering, isTrue);
      expect(s.sync.workingReplyTo, 'u1');
      expect(s.sync.streaming, isNotNull);
      expect(s.sync.streaming!.inReplyTo, 'u1');
      expect(s.sync.isWorking, isTrue);

      s.conn.dispose();
      s.sync.dispose();
    },
  );

  test(
    'multi-image steer keeps image order and preserves the active turn target',
    () async {
      final s = await setup();
      s.ch.push(UserInput(id: 'u1', text: 'primary'));
      await _settle();
      final activeStreaming = s.sync.streaming;

      await s.sync.sendMessage(
        '',
        images: const [
          MessageImage(data: 'FIRST', mime: 'image/jpeg'),
          MessageImage(data: 'SECOND', mime: 'image/png'),
        ],
        streamingBehavior: UserMessageStreamingBehavior.steer,
      );
      await _settle();

      final sent = s.ch.sent.whereType<UserMessage>().last;
      expect(sent.images?.map((image) => image.data), ['FIRST', 'SECOND']);
      final row = messages(s.epk).singleWhere((record) => record.id == sent.id);
      expect(row.images.map((image) => image.data), ['FIRST', 'SECOND']);
      expect(s.sync.workingReplyTo, 'u1');
      expect(s.sync.streaming, same(activeStreaming));
      expect(s.sync.isWorking, isTrue);

      s.ch.push(
        UserInput(
          id: sent.id,
          text: '',
          images: const [
            WireImage(data: 'FIRST', mime: 'image/jpeg'),
            WireImage(data: 'SECOND', mime: 'image/png'),
          ],
          streamingBehavior: UserMessageStreamingBehavior.steer,
        ),
      );
      await _settle();

      final confirmed = messages(
        s.epk,
      ).singleWhere((record) => record.id == sent.id);
      expect(confirmed.pending, isFalse);
      expect(confirmed.images.map((image) => image.data), ['FIRST', 'SECOND']);
      expect(s.sync.workingReplyTo, 'u1');
      expect(s.sync.streaming, same(activeStreaming));
      expect(s.sync.isWorking, isTrue);

      s.conn.dispose();
      s.sync.dispose();
    },
  );

  test('steer echo confirms row without replacing working turn', () async {
    final s = await setup();
    s.ch.push(UserInput(id: 'u1', text: 'primary'));
    await _settle();
    expect(s.sync.workingReplyTo, 'u1');

    await s.sync.sendMessage(
      'refine this',
      streamingBehavior: UserMessageStreamingBehavior.steer,
    );
    await _settle();
    final sent = s.ch.sent.whereType<UserMessage>().lastWhere(
      (m) => m.text == 'refine this',
    );

    s.ch.push(
      UserInput(
        id: sent.id,
        text: 'refine this',
        streamingBehavior: UserMessageStreamingBehavior.steer,
      ),
    );
    await _settle();

    expect(s.sync.workingReplyTo, 'u1');
    expect(s.sync.streaming, isNotNull);
    expect(s.sync.streaming!.inReplyTo, 'u1');
    expect(s.sync.isWorking, isTrue);
    final rows = messages(s.epk);
    expect(rows, hasLength(2));
    var steerRow = rows.where((r) => r.id == sent.id).single;
    expect(steerRow.pending, isFalse);
    expect(steerRow.steering, isTrue, reason: 'echo only means accepted');
    expect((steerRow.toChatMessage() as UserMsg).steering, isTrue);
    expect(index(s.epk)?.status, SessionActivity.working);
    expect(index(s.epk)?.lastMessagePreview, 'refine this');

    s.ch.push(SteerConsumed(id: sent.id));
    await _settle();

    steerRow = messages(s.epk).where((r) => r.id == sent.id).single;
    expect(steerRow.pending, isFalse);
    expect(
      steerRow.steering,
      isFalse,
      reason: 'actual queue delivery clears label',
    );
    expect((steerRow.toChatMessage() as UserMsg).steering, isFalse);

    s.conn.dispose();
    s.sync.dispose();
  });

  test(
    'steer_consumed clears one steering label, not every queued steer',
    () async {
      final s = await setup();
      s.ch.push(UserInput(id: 'u1', text: 'primary'));
      await _settle();

      await s.sync.sendMessage(
        'first steer',
        streamingBehavior: UserMessageStreamingBehavior.steer,
      );
      await s.sync.sendMessage(
        'second steer',
        streamingBehavior: UserMessageStreamingBehavior.steer,
      );
      await _settle();
      final first = s.ch.sent.whereType<UserMessage>().lastWhere(
        (m) => m.text == 'first steer',
      );
      final second = s.ch.sent.whereType<UserMessage>().lastWhere(
        (m) => m.text == 'second steer',
      );
      for (final sent in [first, second]) {
        s.ch.push(
          UserInput(
            id: sent.id,
            text: sent.text,
            streamingBehavior: UserMessageStreamingBehavior.steer,
          ),
        );
      }
      await _settle();
      expect(
        messages(s.epk).where((r) => r.id == first.id).single.steering,
        isTrue,
      );
      expect(
        messages(s.epk).where((r) => r.id == second.id).single.steering,
        isTrue,
      );

      s.ch.push(AgentChunk(inReplyTo: 'u1', delta: 'working'));
      await _settle();
      expect(
        messages(s.epk).where((r) => r.id == first.id).single.steering,
        isTrue,
      );
      expect(
        messages(s.epk).where((r) => r.id == second.id).single.steering,
        isTrue,
      );

      s.ch.push(SteerConsumed(id: first.id));
      await _settle();

      expect(
        messages(s.epk).where((r) => r.id == first.id).single.steering,
        isFalse,
      );
      expect(
        messages(s.epk).where((r) => r.id == second.id).single.steering,
        isTrue,
      );
      s.conn.dispose();
      s.sync.dispose();
    },
  );

  test('agent_done clears only its steering label as a fallback', () async {
    final s = await setup();
    s.ch.push(UserInput(id: 'u1', text: 'primary'));
    await _settle();

    await s.sync.sendMessage(
      'first steer',
      streamingBehavior: UserMessageStreamingBehavior.steer,
    );
    await s.sync.sendMessage(
      'second steer',
      streamingBehavior: UserMessageStreamingBehavior.steer,
    );
    await _settle();
    final first = s.ch.sent.whereType<UserMessage>().lastWhere(
      (m) => m.text == 'first steer',
    );
    final second = s.ch.sent.whereType<UserMessage>().lastWhere(
      (m) => m.text == 'second steer',
    );
    for (final sent in [first, second]) {
      s.ch.push(
        UserInput(
          id: sent.id,
          text: sent.text,
          streamingBehavior: UserMessageStreamingBehavior.steer,
        ),
      );
    }
    await _settle();
    expect(
      messages(s.epk).where((r) => r.id == first.id).single.steering,
      isTrue,
    );
    expect(
      messages(s.epk).where((r) => r.id == second.id).single.steering,
      isTrue,
    );

    s.ch.push(AgentDone(inReplyTo: first.id));
    await _settle();

    expect(
      messages(s.epk).where((r) => r.id == first.id).single.steering,
      isFalse,
    );
    expect(
      messages(s.epk).where((r) => r.id == second.id).single.steering,
      isTrue,
    );
    s.conn.dispose();
    s.sync.dispose();
  });

  test('streaming delta does NOT write to the DB (#7)', () async {
    final s = await setup();
    final before = messages(s.epk).length;
    s.ch.push(AgentChunk(inReplyTo: 'r1', delta: 'partial...'));
    await _settle();
    expect(messages(s.epk).length, before, reason: 'no row for a delta');
    expect(s.sync.streaming, isNotNull);
    expect(s.sync.streaming!.buffer, 'partial...');
    s.conn.dispose();
    s.sync.dispose();
  });

  test(
    'continuous chunks flush before the source becomes quiet (#136)',
    () async {
      final s = await setup();
      var producing = true;
      var emittedDuringBurst = false;
      final sub = s.sync.streamingStream.listen((message) {
        if (producing && (message?.buffer.isNotEmpty ?? false)) {
          emittedDuringBurst = true;
        }
      });

      for (var i = 0; i < 20; i++) {
        s.ch.push(AgentChunk(inReplyTo: 'r1', delta: 'x'));
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      producing = false;

      expect(
        emittedDuringBurst,
        isTrue,
        reason: 'continuous input must not postpone every 16ms UI flush',
      );
      await _settle();
      expect(s.sync.streaming?.buffer, List.filled(20, 'x').join());

      await sub.cancel();
      s.conn.dispose();
      s.sync.dispose();
    },
  );

  test('agent_done finalizes the streamed message + flips to idle', () async {
    final s = await setup();
    s.ch.push(AgentChunk(inReplyTo: 'r1', delta: 'done text'));
    await _settle();
    s.ch.push(AgentDone(inReplyTo: 'r1'));
    await _settle();

    final assistant = messages(
      s.epk,
    ).where((m) => m.role == MsgRole.assistant).toList();
    expect(assistant, hasLength(1));
    expect(assistant.first.text, 'done text');
    expect(s.sync.streaming, isNull);
    expect(index(s.epk)?.status, SessionActivity.idle);
    s.conn.dispose();
    s.sync.dispose();
  });

  test('cancel sends a Cancel frame for the active turn target', () async {
    final s = await setup();
    s.ch.push(UserInput(id: 'u1', text: 'hi'));
    await _settle();

    await s.sync.cancel('u1');
    await _settle();

    final cancel = s.ch.sent.whereType<Cancel>().single;
    expect(cancel.targetId, 'u1');
    s.conn.dispose();
    s.sync.dispose();
  });

  test(
    'cancelled stops the turn but preserves confirmed user history',
    () async {
      final s = await setup();
      s.ch.push(UserInput(id: 'u1', text: 'keep this'));
      await _settle();
      s.ch.push(AgentChunk(inReplyTo: 'u1', delta: 'partial'));
      s.ch.push(Cancelled(inReplyTo: 'cancel-1', targetId: 'u1'));
      await _settle();

      final rows = messages(s.epk);
      expect(
        rows.where((m) => m.id == 'u1' && m.role == MsgRole.user),
        hasLength(1),
      );
      expect(rows.singleWhere((m) => m.id == 'u1').pending, isFalse);
      expect(s.sync.streaming, isNull);
      expect(s.sync.isWorking, isFalse);
      expect(index(s.epk)?.status, SessionActivity.idle);
      s.conn.dispose();
      s.sync.dispose();
    },
  );

  test('cancelled removes a still-pending optimistic user row', () async {
    final s = await setup();
    await s.sync.sendMessage('stop before echo');
    await _settle();
    final id = (s.ch.sent.whereType<UserMessage>().last).id;
    expect(messages(s.epk).single.pending, isTrue);

    s.ch.push(Cancelled(inReplyTo: 'cancel-1', targetId: id));
    await _settle();

    expect(messages(s.epk), isEmpty);
    expect(s.sync.streaming, isNull);
    expect(s.sync.isWorking, isFalse);
    expect(index(s.epk)?.status, SessionActivity.idle);
    s.conn.dispose();
    s.sync.dispose();
  });

  test(
    'server error clears pending chunk flush so chat does not stay working',
    () async {
      final s = await setup();
      s.ch.push(UserInput(id: 'u1', text: 'hi'));
      await _settle();
      s.ch.push(AgentChunk(inReplyTo: 'u1', delta: 'partial'));
      s.ch.push(
        ErrorMessage(
          inReplyTo: 'cancel-1',
          code: 'internal_error',
          message: 'No active Pi context to abort',
        ),
      );
      await _settle();

      expect(s.sync.streaming, isNull);
      expect(s.sync.isWorking, isFalse);
      expect(index(s.epk)?.status, SessionActivity.idle);
      final errorTexts = messages(
        s.epk,
      ).where((m) => m.role == MsgRole.assistant).map((m) => m.text);
      expect(errorTexts, contains(startsWith('⚠ internal_error:')));
      s.conn.dispose();
      s.sync.dispose();
    },
  );

  test('isWorking spans the whole turn (echo → agent_done)', () async {
    final s = await setup();
    expect(s.sync.isWorking, isFalse);
    final flags = <bool>[];
    final sub = s.sync.workingStream.listen(flags.add);

    s.ch.push(UserInput(id: 'u1', text: 'hi'));
    await _settle();
    expect(s.sync.isWorking, isTrue, reason: 'working from the echo');

    s.ch.push(AgentDone(inReplyTo: 'u1'));
    await _settle();
    expect(s.sync.isWorking, isFalse, reason: 'idle after agent_done');
    expect(flags, [true, false]);

    await sub.cancel();
    s.conn.dispose();
    s.sync.dispose();
  });

  test('switching sessions resets the in-memory turn state — working/streaming '
      'do NOT leak into the next chat (plan/32)', () async {
    final s = await setup();

    // Session 1 is mid-turn: working flag + streaming buffer populated.
    s.ch.push(AgentChunk(inReplyTo: 'r1', delta: 'thinking...'));
    await _settle();
    expect(s.sync.isWorking, isTrue);
    expect(s.sync.streaming, isNotNull);
    expect(s.sync.workingReplyTo, 'r1');

    final flags = <bool>[];
    final sub = s.sync.workingStream.listen(flags.add);

    // Switch the writer to a DIFFERENT session (what the chat does on a
    // tablet session switch). Must clear the in-memory signals.
    await s.sync.activate('epk_other_session', 'main');
    await _settle();

    expect(
      s.sync.isWorking,
      isFalse,
      reason: 'chat 2 must not inherit chat 1 working',
    );
    expect(
      s.sync.streaming,
      isNull,
      reason: 'chat 1 streaming buffer must not show in chat 2',
    );
    expect(s.sync.workingReplyTo, isNull);
    expect(
      flags,
      contains(false),
      reason: 'listeners are notified the flag cleared',
    );

    // The previous session's DURABLE index must stay "working" — the Pi
    // may still be mid-turn and Home reflects it (relay broadcast + DB).
    // Clearing the in-memory signals must NOT idle the box row.
    expect(
      index(s.epk)?.status,
      SessionActivity.working,
      reason: 'switching away must not idle chat 1 in the DB',
    );

    await sub.cancel();
    s.conn.dispose();
    s.sync.dispose();
  });

  test(
    'cursor: streaming is seeded EMPTY at turn start, before any chunk',
    () async {
      final s = await setup();
      expect(s.sync.streaming, isNull);

      // Optimistic send seeds the thinking cursor (online).
      await s.sync.sendMessage('hi');
      await _settle();
      expect(s.sync.streaming, isNotNull, reason: 'cursor during thinking');
      expect(s.sync.streaming!.buffer, isEmpty);

      s.conn.dispose();
      s.sync.dispose();
    },
  );

  test(
    'cursor: foreign echo seeds it; a text-less turn clears it on done',
    () async {
      final s = await setup();
      s.ch.push(UserInput(id: 'u9', text: 'from terminal'));
      await _settle();
      expect(s.sync.streaming, isNotNull, reason: 'cursor before any chunk');
      expect(s.sync.streaming!.buffer, isEmpty);

      // Turn produces no text (e.g. only tool calls) → done still clears it.
      s.ch.push(AgentDone(inReplyTo: 'u9'));
      await _settle();
      expect(s.sync.streaming, isNull, reason: 'done clears the cursor');
      s.conn.dispose();
      s.sync.dispose();
    },
  );

  test('cursor: a chunk appends onto the seeded empty buffer', () async {
    final s = await setup();
    s.ch.push(UserInput(id: 'u1', text: 'hi'));
    await _settle();
    s.ch.push(AgentChunk(inReplyTo: 'u1', delta: 'tok'));
    await _settle();
    expect(s.sync.streaming!.buffer, 'tok', reason: 'appended, not replaced');
    s.conn.dispose();
    s.sync.dispose();
  });

  test(
    'sequential: text → tool → text renders in chronological order',
    () async {
      final s = await setup();
      s.ch.push(UserInput(id: 'u1', text: 'go'));
      await _settle();
      s.ch.push(AgentChunk(inReplyTo: 'u1', delta: 'let me check'));
      await _settle(); // 16ms flush settles into the streaming buffer
      s.ch.push(ToolRequest(toolCallId: 'tc1', tool: 'Read', args: {}));
      await _settle();
      s.ch.push(ToolResult(toolCallId: 'tc1', result: {'ok': true}));
      await _settle();
      s.ch.push(AgentChunk(inReplyTo: 'u1', delta: 'all done'));
      await _settle();
      s.ch.push(AgentDone(inReplyTo: 'u1'));
      await _settle();

      final m = messages(s.epk);
      expect(
        m.map((r) => r.role),
        [MsgRole.user, MsgRole.assistant, MsgRole.tool, MsgRole.assistant],
        reason: 'pre-tool text, then tool, then post-tool text — in order',
      );
      expect(m[1].text, 'let me check');
      expect(m[2].tool?.tool, 'Read');
      expect(m[3].text, 'all done');
      s.conn.dispose();
      s.sync.dispose();
    },
  );

  test('re-applying an IDENTICAL SessionHistory is idempotent — no box churn, '
      'so the relay re-sending history on every reconnect no longer tears the '
      'list down and rebuilds it (plan/32 flicker fix)', () async {
    final s = await setup();
    final read = SessionReadRepository(LocalBoxes());
    var emits = 0;
    final sub = read.watchMessages(s.epk, 'main').listen((_) => emits++);
    await _settle();

    SessionHistory hist(String inReplyTo) => SessionHistory(
      inReplyTo: inReplyTo,
      sessionStartedAt: 0,
      events: const [
        UserInputEvt(ts: 1, id: 'u1', text: 'hi'),
        AgentMessageEvt(ts: 2, inReplyTo: 'a1', text: 'hello'),
        ToolRequestEvt(ts: 3, toolCallId: 'c1', tool: 'Read', args: null),
      ],
      eos: true,
    );

    s.ch.push(hist('sync1'));
    await _settle();
    final afterFirst = emits;
    expect(afterFirst, greaterThan(1), reason: 'first apply populates rows');
    expect(messages(s.epk).map((r) => r.role), [
      MsgRole.user,
      MsgRole.assistant,
      MsgRole.tool,
    ]);

    // Relay re-delivers the SAME history (different in_reply_to, identical
    // events) — the reconcile must write nothing → no watch event → no emit.
    s.ch.push(hist('sync2'));
    await _settle();
    expect(
      emits,
      afterFirst,
      reason: 'identical re-apply must not emit (no list rebuild/flicker)',
    );

    await sub.cancel();
    s.conn.dispose();
    s.sync.dispose();
  });

  test('history from another room cannot replace the active chat', () async {
    final s = await setup();
    s.ch.push(UserInput(id: 'current', text: 'Keep this chat'));
    await _settle();

    s.ch.push(
      ServerMessage.fromJson({
        'type': 'session_history',
        'in_reply_to': 'other-room-sync',
        'session_started_at': 0,
        'room_id': 'other-room',
        'eos': true,
        'events': [
          {
            'type': 'user_input',
            'ts': 1,
            'id': 'foreign',
            'text': 'Other chat',
          },
        ],
      }),
    );
    await _settle();

    expect(messages(s.epk).map((r) => r.id), ['current']);
    expect(messages(s.epk).single.text, 'Keep this chat');
    s.conn.dispose();
    s.sync.dispose();
  });

  test(
    'history sync preserves saved legacy prompts as local history',
    () async {
      final s = await setup();
      final box = LocalBoxes().openMsgsBox(s.epk, 'main');
      for (var i = 0; i < 3; i++) {
        await box.put(i, {
          'id': 'legacy-$i',
          'seq': i,
          'role': 'askUser',
          'ts': i,
          'ask_user': {
            'question': 'Saved question $i',
            'context': 'Saved context',
            'options': [
              {'title': 'A'},
            ],
            'allow_multiple': false,
            'allow_freeform': true,
            'allow_comment': true,
            'resolved': i != 0,
            'cancelled': i == 2,
            if (i == 1) 'answer_label': 'A',
          },
        });
      }
      await _settle();
      final saved = messages(s.epk).map((r) => r.askUser!.toJson()).toList();

      for (final events in <List<SessionHistoryEvent>>[
        const [UserInputEvt(ts: 10, id: 'latest', text: 'new message')],
        const [],
      ]) {
        s.ch.push(
          SessionHistory(
            inReplyTo: 'sync-legacy',
            sessionStartedAt: 0,
            roomId: 'main',
            eos: true,
            truncated: true,
            events: events,
          ),
        );
        await _settle();
        expect(messages(s.epk).map((r) => r.id), [
          'legacy-0',
          'legacy-1',
          'legacy-2',
          if (events.isNotEmpty) 'latest',
        ]);
        final legacy = messages(s.epk).where((r) => r.role == MsgRole.askUser);
        expect(legacy.map((r) => r.id), ['legacy-0', 'legacy-1', 'legacy-2']);
        expect(legacy.map((r) => r.askUser!.toJson()).toList(), saved);
      }
      s.conn.dispose();
      s.sync.dispose();
    },
  );

  test(
    'history sync keeps archived questions between their neighbors and pending users last',
    () async {
      final s = await setup();
      final box = LocalBoxes().openMsgsBox(s.epk, 'main');
      final saved = [
        MessageRecord(
          id: 'before',
          seq: 0,
          role: MsgRole.user,
          text: 'Before the question',
          ts: DateTime.fromMillisecondsSinceEpoch(300),
        ),
        MessageRecord(
          id: 'legacy-question',
          seq: 1,
          role: MsgRole.askUser,
          ts: DateTime.fromMillisecondsSinceEpoch(200),
          askUser: const AskUserPromptData(
            question: 'Which route?',
            context: 'Saved context',
            options: [],
            allowMultiple: false,
            allowFreeform: true,
            allowComment: false,
          ),
        ),
        MessageRecord(
          id: 'after',
          seq: 2,
          role: MsgRole.assistant,
          text: 'After the question',
          ts: DateTime.fromMillisecondsSinceEpoch(100),
        ),
        MessageRecord(
          id: 'legacy-tail',
          seq: 3,
          role: MsgRole.askUser,
          ts: DateTime.fromMillisecondsSinceEpoch(350),
          askUser: const AskUserPromptData(
            question: 'One more question?',
            context: '',
            options: [],
            allowMultiple: false,
            allowFreeform: true,
            allowComment: false,
          ),
        ),
        MessageRecord(
          id: 'pending',
          seq: 4,
          role: MsgRole.user,
          text: 'Still awaiting echo',
          pending: true,
          ts: DateTime.fromMillisecondsSinceEpoch(400),
        ),
      ];
      for (final row in saved) {
        await box.put(row.seq, row.toJson());
      }
      await _settle();
      var writes = 0;
      final sub = box.watch().listen((_) => writes++);

      for (var sync = 0; sync < 2; sync++) {
        s.ch.push(
          SessionHistory(
            inReplyTo: 'ordered-sync-$sync',
            sessionStartedAt: 0,
            eos: true,
            // Server order, not timestamps, remains authoritative.
            events: const [
              UserInputEvt(ts: 300, id: 'before', text: 'Before the question'),
              AgentMessageEvt(
                ts: 100,
                inReplyTo: 'after',
                text: 'After the question',
              ),
              UserInputEvt(ts: 50, id: 'new', text: 'New server message'),
            ],
          ),
        );
        final writesBeforeSync = writes;
        await _settle();
        final rows = messages(s.epk);
        expect(rows.map((r) => r.id), [
          'before',
          'legacy-question',
          'after',
          'legacy-tail',
          'new',
          'pending',
        ]);
        expect(rows[1].askUser!.toJson(), saved[1].askUser!.toJson());
        expect(rows.last.pending, isTrue);
        if (sync == 1) {
          expect(writes, writesBeforeSync, reason: 'repeat sync is idempotent');
        }
      }
      await sub.cancel();
      s.conn.dispose();
      s.sync.dispose();
    },
  );

  for (final repeatedText in [false, true]) {
    test('archived questions keep their position among shared assistant IDs '
        '(repeated text: $repeatedText)', () async {
      final s = await setup();
      final box = LocalBoxes().openMsgsBox(s.epk, 'main');
      final texts = repeatedText
          ? ['Segment', 'Segment', 'Segment']
          : ['Before', 'After', 'Final'];
      final saved = [
        for (var i = 0; i < 3; i++) ...[
          MessageRecord(
            id: 'shared-turn',
            seq: i == 0 ? 0 : i + 1,
            role: MsgRole.assistant,
            text: texts[i],
            ts: DateTime.fromMillisecondsSinceEpoch(10),
          ),
          if (i == 0)
            MessageRecord(
              id: 'archived',
              seq: 1,
              role: MsgRole.askUser,
              ts: DateTime.fromMillisecondsSinceEpoch(20),
              askUser: const AskUserPromptData(
                question: 'Saved question',
                context: '',
                options: [],
                allowMultiple: false,
                allowFreeform: true,
                allowComment: false,
              ),
            ),
        ],
      ];
      for (final row in saved) {
        await box.put(row.seq, row.toJson());
      }
      await _settle();

      for (var sync = 0; sync < 2; sync++) {
        s.ch.push(
          SessionHistory(
            inReplyTo: 'shared-id-sync-$sync',
            sessionStartedAt: 0,
            eos: true,
            events: [
              for (final text in texts)
                AgentMessageEvt(ts: 10, inReplyTo: 'shared-turn', text: text),
            ],
          ),
        );
        await _settle();
        final rows = messages(s.epk);
        expect(rows.map((r) => r.id), [
          'shared-turn',
          'archived',
          'shared-turn',
          'shared-turn',
        ]);
        expect(
          rows.where((r) => r.role == MsgRole.assistant).map((r) => r.text),
          texts,
        );
        expect(rows[1].askUser!.question, 'Saved question');
      }
      s.conn.dispose();
      s.sync.dispose();
    });
  }

  test('session_history retains every user image in stable order', () async {
    final s = await setup();
    s.ch.push(
      SessionHistory(
        inReplyTo: 'images-history',
        sessionStartedAt: 0,
        eos: true,
        events: const [
          UserInputEvt(
            ts: 1,
            id: 'u-images',
            text: 'album',
            images: [
              WireImage(data: 'FIRST', mime: 'image/jpeg'),
              WireImage(data: 'SECOND', mime: 'image/png'),
            ],
          ),
        ],
      ),
    );
    await _settle();

    expect(messages(s.epk).single.images.map((image) => image.data), [
      'FIRST',
      'SECOND',
    ]);
    s.conn.dispose();
    s.sync.dispose();
  });

  test(
    'switching the writer to a new session: a late frame from the OLD '
    "connection is dropped — it neither writes the new box nor appears in the "
    "new session's read projection (plan/32f session-switch bleed)",
    () async {
      final s = await setup(); // bound to s.epk (peer A)
      s.ch.push(UserInput(id: 'a1', text: 'from chat1'));
      await _settle();
      expect(messages(s.epk), hasLength(1));

      // Switch the writer to chat 2 (epkB) WITHOUT a new channel — simulates
      // the window where the chat calls activate(epkB) before switchTo tears
      // the old peer's channel down. _activeEpk moves; the old channel (origin
      // = peer A) is still draining.
      const epkB = 'epk_chat2_zzz';
      final read = SessionReadRepository(LocalBoxes());
      final seenLens = <int>[];
      final sub = read
          .watchMessages(epkB, 'main')
          .listen((rows) => seenLens.add(rows.length));
      await s.sync.activate(epkB, 'main');
      await _settle();

      // Straggler frame on the OLD (peer A) channel.
      s.ch.push(UserInput(id: 'late', text: 'late chat1'));
      await _settle();

      expect(
        messages(epkB),
        isEmpty,
        reason: 'old-connection frame must not bleed into the new box',
      );
      expect(
        seenLens.every((n) => n == 0),
        isTrue,
        reason: "chat 2's projection never shows chat 1 rows",
      );
      expect(
        messages(s.epk),
        hasLength(1),
        reason: 'chat 1 box keeps exactly its own row (late frame dropped)',
      );

      await sub.cancel();
      s.conn.dispose();
      s.sync.dispose();
    },
  );

  test('compaction ServerMessage writes a system row that projects to a '
      'CompactionMsg system bubble (plan/32)', () async {
    final s = await setup();
    s.ch.push(
      Compaction(
        summary: 'recapped the thread',
        tokensBefore: 12000,
        ts: 1700000000000,
      ),
    );
    await _settle();

    final m = messages(s.epk);
    expect(m, hasLength(1));
    expect(m.first.role, MsgRole.compaction);
    expect(m.first.text, 'recapped the thread');
    expect(m.first.tokensBefore, 12000);
    // Projects to the domain system-bubble message.
    expect(m.first.toChatMessage(), isA<CompactionMsg>());

    s.conn.dispose();
    s.sync.dispose();
  });

  test('compaction event in session_history reconstructs the system row on '
      're-sync (plan/32)', () async {
    final s = await setup();
    s.ch.push(
      SessionHistory(
        inReplyTo: 'sync1',
        sessionStartedAt: 0,
        events: const [
          UserInputEvt(ts: 1, id: 'u1', text: 'hi'),
          AgentMessageEvt(ts: 2, inReplyTo: 'a1', text: 'hello'),
          CompactionEvt(ts: 3, summary: 'compacted', tokensBefore: 5000),
        ],
        eos: true,
      ),
    );
    await _settle();

    final m = messages(s.epk);
    expect(m.map((r) => r.role), [
      MsgRole.user,
      MsgRole.assistant,
      MsgRole.compaction,
    ]);
    expect(m.last.text, 'compacted');
    expect(m.last.tokensBefore, 5000);
    expect(m.last.toChatMessage(), isA<CompactionMsg>());

    s.conn.dispose();
    s.sync.dispose();
  });

  test(
    'clearActiveSession wipes rows, index, and in-memory turn state',
    () async {
      final s = await setup();
      s.ch.push(UserInput(id: 'u1', text: 'hi'));
      await _settle();
      expect(messages(s.epk), hasLength(1));
      expect(s.sync.isWorking, isTrue);
      expect(s.sync.streaming, isNotNull);

      await s.sync.clearActiveSession();
      await _settle();
      expect(messages(s.epk), isEmpty);
      expect(index(s.epk), isNull);
      expect(s.sync.isWorking, isFalse);
      expect(s.sync.streaming, isNull);
      s.conn.dispose();
      s.sync.dispose();
    },
  );

  test(
    'relay working=false clears stale active-chat local working state',
    () async {
      final s = await setup();
      s.ch.push(UserInput(id: 'u1', text: 'hi'));
      await _settle();
      expect(s.sync.isWorking, isTrue);

      s.ch.pushControl(
        RoomAnnounced(peer: s.epk, roomId: 'main', startedAt: 1),
      );
      s.ch.pushControl(
        RoomMetaUpdated(
          peer: s.epk,
          roomId: 'main',
          working: true,
          hasModel: false,
          hasThinking: false,
        ),
      );
      await _settle();
      expect(s.sync.isWorking, isTrue);

      s.ch.pushControl(
        RoomMetaUpdated(
          peer: s.epk,
          roomId: 'main',
          working: false,
          hasModel: false,
          hasThinking: false,
        ),
      );
      await _settle();
      expect(s.conn.isRoomWorking(s.epk, 'main'), isFalse);
      expect(s.sync.isWorking, isFalse);
      expect(s.sync.streaming, isNull);
      s.conn.dispose();
      s.sync.dispose();
    },
  );

  // Plan/32 safety net — a sent message whose echo never comes back must not
  // spin forever; the optimistic bubble is removed SILENTLY after the timeout.
  group('no-echo send timeout', () {
    const short = Duration(milliseconds: 60);

    test(
      '(a) pending bubble is removed silently when no echo arrives',
      () async {
        final s = await setup(pendingSendTimeout: short);
        await s.sync.sendMessage('hello');
        await _settle();
        expect(messages(s.epk), hasLength(1), reason: 'optimistic pending row');
        expect(messages(s.epk).first.pending, isTrue);
        expect(s.sync.isWorking, isTrue);
        expect(s.sync.streaming, isNotNull, reason: 'thinking cursor seeded');

        // No echo — wait past the timeout window.
        await Future<void>.delayed(const Duration(milliseconds: 140));
        await _settle();

        expect(
          messages(s.epk),
          isEmpty,
          reason: 'bubble removed, no failed state',
        );
        expect(
          s.sync.isWorking,
          isFalse,
          reason: 'working cleared for this id',
        );
        expect(s.sync.streaming, isNull, reason: 'thinking cursor cleared');
        expect(index(s.epk)?.status, SessionActivity.idle);
        expect(s.sync.debugPendingSendTimerCount, 0);
        s.conn.dispose();
        s.sync.dispose();
      },
    );

    test(
      '(b) echo within the window confirms the row and cancels the timer',
      () async {
        final s = await setup(pendingSendTimeout: short);
        await s.sync.sendMessage('hello');
        await _settle();
        expect(s.sync.debugPendingSendTimerCount, 1, reason: 'timer armed');
        final id = s.ch.sent.whereType<UserMessage>().last.id;

        // Echo arrives promptly → confirms + disarms.
        s.ch.push(UserInput(id: id, text: 'hello'));
        await _settle();
        expect(messages(s.epk), hasLength(1));
        expect(
          messages(s.epk).first.pending,
          isFalse,
          reason: 'confirmed by echo',
        );
        expect(
          s.sync.debugPendingSendTimerCount,
          0,
          reason: 'echo cancelled timer',
        );

        // Wait PAST the timeout — the cancelled timer must NOT remove the row.
        await Future<void>.delayed(const Duration(milliseconds: 140));
        await _settle();
        expect(
          messages(s.epk),
          hasLength(1),
          reason: 'row survives the window',
        );
        expect(messages(s.epk).first.pending, isFalse);
        s.conn.dispose();
        s.sync.dispose();
      },
    );

    test(
      '(c) timers are cancelled on session switch and on dispose (no leak)',
      () async {
        // Session switch path.
        final s = await setup(pendingSendTimeout: short);
        await s.sync.sendMessage('one');
        await _settle();
        expect(s.sync.debugPendingSendTimerCount, 1);

        await s.sync.activate('epk_switch_target', 'main');
        await _settle();
        expect(
          s.sync.debugPendingSendTimerCount,
          0,
          reason: 'session switch cancels + clears pending timers',
        );

        // dispose path (fresh service so the switch above doesn't mask it).
        final s2 = await setup(pendingSendTimeout: short);
        await s2.sync.sendMessage('two');
        await _settle();
        expect(s2.sync.debugPendingSendTimerCount, 1);
        s2.sync.dispose();
        expect(
          s2.sync.debugPendingSendTimerCount,
          0,
          reason: 'dispose cancels + clears pending timers',
        );

        s.conn.dispose();
        s.sync.dispose();
        s2.conn.dispose();
      },
    );

    test('(d) an offline (held-pending) send is reaped too', () async {
      // No channel ever adopted → sendMessage takes the offline path. Decision:
      // held-pending is reaped 20s after its ts as well (nothing spins forever).
      final conn = ConnectionManager(
        factory: (_, _) async => _FakeChannel(),
        storage: _FakeStorage(),
      );
      final sync = SyncService(conn, LocalBoxes(), pendingSendTimeout: short);
      final epk = 'epk_offline_${++_counter}';
      await sync.activate(epk, 'main');
      await _settle();

      await sync.sendMessage('typed while offline');
      await _settle();
      expect(messages(epk), hasLength(1), reason: 'held pending row written');
      expect(messages(epk).first.pending, isTrue);
      expect(
        sync.debugPendingSendTimerCount,
        1,
        reason: 'reaper armed offline',
      );

      await Future<void>.delayed(const Duration(milliseconds: 140));
      await _settle();
      expect(
        messages(epk),
        isEmpty,
        reason: 'offline bubble reaped (decision)',
      );
      conn.dispose();
      sync.dispose();
    });

    test(
      '(e) returning to a session reaps a bubble already past the window',
      () async {
        // Quick exit then return: the live timer is cancelled on switch-away,
        // but _loadIndex re-arms on return using the saved ts → an already-stale
        // row fires immediately. Covers app-restart + quick-switch orphans.
        final s = await setup(pendingSendTimeout: short);
        await s.sync.sendMessage('hi');
        await _settle();
        expect(messages(s.epk), hasLength(1));

        // Leave quickly → live timer cancelled; row stays pending in the box.
        await s.sync.activate('epk_away_${++_counter}', 'main');
        await _settle();
        expect(
          s.sync.debugPendingSendTimerCount,
          0,
          reason: 'timers cleared on switch',
        );
        expect(
          messages(s.epk),
          hasLength(1),
          reason: 'orphaned row still in box',
        );

        // Time passes beyond the window while away from the session.
        await Future<void>.delayed(const Duration(milliseconds: 140));
        expect(
          messages(s.epk),
          hasLength(1),
          reason: 'no live timer reaps it while away',
        );

        // Return → load re-arms by ts → already stale → reaped on arrival.
        await s.sync.activate(s.epk, 'main');
        await _settle();
        expect(
          messages(s.epk),
          isEmpty,
          reason: 'stale pending reaped on return',
        );
        s.conn.dispose();
        s.sync.dispose();
      },
    );
  });
}
