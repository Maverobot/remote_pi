import 'package:app/domain/background_progress.dart';
import 'package:app/protocol/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Map<String, dynamic> observation({
    String state = 'running',
    Object? elapsed = 5000,
  }) => {
    'session_id': 'parent',
    'epoch': 'epoch',
    'available': true,
    'truncated': false,
    'groups': [
      {
        'id': 'dispatch',
        'label': 'Implementation',
        'tasks': [
          {
            'id': 'worker',
            'label': '实现',
            'state': state,
            'elapsed_ms': ?elapsed,
          },
        ],
      },
    ],
  };
  BackgroundProgressMessage parse(Object? payload) =>
      (ServerMessage.fromJson({
                'type': 'pong',
                'in_reply_to': 'phone-interest',
                'background_progress': payload,
              })
              as Pong)
          .backgroundProgress!;

  test(
    'ordinary ping/pong and history stay compatible; renewal is additive',
    () {
      expect(Ping(id: 'old').toJson(), {'type': 'ping', 'id': 'old'});
      expect(SessionSync(id: 'history').toJson(), {
        'type': 'session_sync',
        'id': 'history',
      });
      expect(
        Ping(
          id: 'new',
          backgroundProgress: true,
        ).toJson()['background_progress'],
        isTrue,
      );
      expect(
        (ServerMessage.fromJson({'type': 'pong', 'in_reply_to': 'old'}) as Pong)
            .backgroundProgress,
        isNull,
      );
    },
  );
  test(
    'pong parses bounded observations and preserves source-language labels',
    () {
      final message = parse(observation());
      expect(message.inReplyTo, 'phone-interest');
      expect(message.available, isTrue);
      expect(message.groups.single.tasks.single.label, '实现');
      expect(
        message.groups.single.tasks.single.elapsed,
        const Duration(seconds: 5),
      );
    },
  );
  test('future states and missing time do not become running or zero', () {
    final message = parse(observation(state: 'future', elapsed: null));
    expect(
      message.groups.single.tasks.single.state,
      BackgroundTaskState.unknown,
    );
    expect(message.groups.single.tasks.single.elapsed, isNull);
    for (final state in ['queued', 'paused', 'waiting', 'partial']) {
      expect(
        parse(observation(state: state)).groups.single.tasks.single.state.name,
        state,
      );
    }
  });
  test('terminal rows disappear; malformed data is not empty success', () {
    for (final state in [
      'complete',
      'failed',
      'stopped',
      'cancelled',
      'rejected',
    ]) {
      final message = parse(observation(state: state));
      expect(message.available, isTrue);
      expect(message.groups, isEmpty);
    }
    expect(parse({...observation(), 'groups': []}).available, isTrue);
    for (final payload in [
      observation(elapsed: -1),
      {...observation(), 'groups': 'bad'},
      null,
      [],
    ]) {
      final message = parse(payload);
      expect(message.available, isFalse);
      expect(message.inReplyTo, 'phone-interest');
    }
  });
  test('malformed scope retains correlation without inventing an identity', () {
    for (final field in ['session_id', 'epoch']) {
      for (final invalid in [null, '', 3, 'x' * 257]) {
        final message = parse({...observation(), field: invalid});
        expect(message.available, isFalse);
        expect(message.inReplyTo, 'phone-interest');
        expect(field == 'epoch' ? message.epoch : message.sessionId, isNull);
      }
    }
  });
  test('invalid bounds and duplicate task identities are unavailable', () {
    final duplicate = observation();
    final tasks = (duplicate['groups'] as List).first['tasks'] as List;
    tasks.add(tasks.first);
    expect(parse(duplicate).available, isFalse);
    final tooLarge = observation();
    ((tooLarge['groups'] as List).first['tasks'] as List).first['label'] =
        'x' * 161;
    expect(parse(tooLarge).available, isFalse);
  });
  test('elapsed advances only for known running durations while fresh', () {
    final progress = BackgroundProgress(
      sessionId: 'parent',
      epoch: 'epoch',
      truncated: false,
      freshness: BackgroundFreshness.fresh,
      groups: [
        BackgroundGroup(
          id: 'g',
          tasks: [
            const BackgroundTask(
              id: 'r',
              label: 'running',
              state: BackgroundTaskState.running,
              elapsed: Duration(seconds: 5),
            ),
            const BackgroundTask(
              id: 'p',
              label: 'paused',
              state: BackgroundTaskState.paused,
              elapsed: Duration(seconds: 4),
            ),
            const BackgroundTask(
              id: 'u',
              label: 'unknown',
              state: BackgroundTaskState.unknown,
            ),
          ],
        ),
      ],
    );
    final tick = progress.advance(const Duration(seconds: 2));
    expect(tick.groups.single.tasks.map((task) => task.elapsed), [
      const Duration(seconds: 7),
      const Duration(seconds: 4),
      null,
    ]);
    final frozen = tick.advance(
      Duration.zero,
      freshness: BackgroundFreshness.offline,
    );
    expect(
      frozen.advance(const Duration(days: 1)).groups.single.tasks.first.elapsed,
      const Duration(seconds: 7),
    );
  });
}
