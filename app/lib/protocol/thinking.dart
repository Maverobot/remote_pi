import 'package:app/domain/thinking.dart';

class ThinkingSnapshot {
  final ThinkingObservation observation;
  final String roomId;
  final int ts;
  final int? historyIndex;
  final int? beforeEvent;
  const ThinkingSnapshot({
    required this.observation,
    required this.roomId,
    required this.ts,
    this.historyIndex,
    this.beforeEvent,
  });

  static ThinkingSnapshot? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final observation = ThinkingObservation.tryFromJson(raw);
    final ts = raw['ts'];
    if (observation == null ||
        !thinkingId(raw['room_id']) ||
        !thinkingInteger(ts) ||
        (ts as int) > 8640000000000000) {
      return null;
    }
    int? index;
    int? before;
    if (raw.containsKey('history')) {
      final history = raw['history'];
      if (history is! Map ||
          !thinkingInteger(history['index']) ||
          !thinkingInteger(history['before_event'])) {
        return null;
      }
      index = history['index'] as int;
      before = history['before_event'] as int;
    }
    // Local interruption is never accepted as producer authority.
    return ThinkingSnapshot(
      observation: observation.interrupted(false),
      roomId: raw['room_id'] as String,
      ts: ts,
      historyIndex: index,
      beforeEvent: before,
    );
  }

  Map<String, Object> toJson() => {
    ...observation.toJson()..remove('locally_interrupted'),
    'room_id': roomId,
    'ts': ts,
    if (historyIndex != null)
      'history': {'index': historyIndex!, 'before_event': beforeEvent!},
  };
}

class ThinkingHistoryManifest {
  final ThinkingScope scope;
  final bool reset;
  final int count;
  final bool truncated;
  const ThinkingHistoryManifest({
    required this.scope,
    required this.reset,
    required this.count,
    required this.truncated,
  });

  static ThinkingHistoryManifest? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final scope = ThinkingScope.tryFromJson(raw);
    if (scope == null ||
        !['reply', 'reset'].contains(raw['kind']) ||
        !thinkingInteger(raw['count']) ||
        raw['truncated'] is! bool) {
      return null;
    }
    if (raw['kind'] == 'reset' && raw['count'] != 0) return null;
    return ThinkingHistoryManifest(
      scope: scope,
      reset: raw['kind'] == 'reset',
      count: raw['count'] as int,
      truncated: raw['truncated'] as bool,
    );
  }
}
