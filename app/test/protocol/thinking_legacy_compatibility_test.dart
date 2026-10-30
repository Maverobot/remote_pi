import 'dart:convert';
import 'package:app/protocol/protocol.dart';
import 'package:app/domain/thinking.dart';
import 'package:app/data/local/records/message_record.dart';
import 'package:flutter_test/flutter_test.dart';
import '../fixtures/legacy_thinking_compatibility.dart';

void main() {
  final thinking = <String, Object>{
    'session_id': 'S',
    'epoch': 'E',
    'room_id': 'R',
    'message_id': 'm',
    'revision': 1,
    'status': 'streaming',
    'text': ' Provider summary.\n',
    'ts': 1,
  };
  test(
    'known thinking carrier and supplements leave frozen old streaming intact',
    () {
      final old = LegacyThinkingClient();
      for (final payload in [
        thinking,
        {
          ...thinking,
          'history': {'index': 0, 'before_event': 1},
        },
      ]) {
        final frame = {
          'type': 'pong',
          'in_reply_to': 'sync',
          'thinking': payload,
        };
        old.receive(jsonEncode(frame));
        expect(
          (ServerMessage.fromJson(frame) as Pong).thinking!.observation.text,
          ' Provider summary.\n',
        );
      }
      old.receive(
        jsonEncode({
          'type': 'session_history',
          'in_reply_to': 'sync',
          'session_started_at': 1,
          'eos': true,
          'events': [
            {
              'type': 'agent_message',
              'in_reply_to': 'u',
              'ts': 1,
              'text': 'answer',
            },
          ],
          'thinking_history': {
            'kind': 'reply',
            'session_id': 'S',
            'epoch': 'E',
            'count': 1,
            'truncated': false,
          },
        }),
      );
      expect(old.streaming, 'ordinary answer');
      expect(old.errors, isEmpty);
      expect(old.history, ['answer']);
      final record = MessageRecord(
        id: 'm',
        seq: 0,
        role: MsgRole.assistant,
        ts: DateTime.fromMillisecondsSinceEpoch(1),
        thinking: ThinkingObservation.tryFromJson(thinking),
      );
      expect(old.assistantText(record.toJson()), isEmpty);
      old.receive(jsonEncode({'type': 'thinking_delta'}));
      expect(old.errors, ['unsupported_type']);
      expect(old.streaming, isEmpty);
    },
  );

  test(
    'malformed optional content is inert; present malformed manifest stays distinct',
    () {
      for (final bad in [
        null,
        1,
        {},
        {...thinking, 'revision': 0},
        {...thinking, 'ts': double.infinity},
        {
          ...thinking,
          'history': {'index': -1, 'before_event': 0},
        },
        {...thinking, 'status': 'mystery'},
      ]) {
        final pong =
            ServerMessage.fromJson({
                  'type': 'pong',
                  'in_reply_to': 'p',
                  'thinking': bad,
                })
                as Pong;
        expect(pong.thinking, isNull);
      }
      final base = <String, dynamic>{
        'type': 'session_history',
        'in_reply_to': 'sync',
        'session_started_at': 0,
        'events': [],
        'eos': true,
      };
      expect(
        (ServerMessage.fromJson(base) as SessionHistory).thinkingHistoryPresent,
        isFalse,
      );
      final malformed =
          ServerMessage.fromJson({...base, 'thinking_history': null})
              as SessionHistory;
      expect(malformed.thinkingHistoryPresent, isTrue);
      expect(malformed.thinkingHistory, isNull);
      expect(
        (ServerMessage.fromJson({'type': 'pong', 'in_reply_to': 'legacy'})
                as Pong)
            .thinking,
        isNull,
      );
    },
  );
}
