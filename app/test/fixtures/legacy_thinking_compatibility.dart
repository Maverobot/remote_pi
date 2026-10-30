import 'dart:convert';

/// Minimal executable public branches pinned to remote_pi 146ff4d6:
/// protocol.dart Pong/SessionHistory + peer_channel unsupported_type conversion
/// + sync_service Pong/error handling. No new parser is used in this fixture.
class LegacyThinkingClient {
  String streaming = 'ordinary answer';
  final List<String> errors = [];
  final List<String> history = [];

  void receive(String encoded) {
    final j = jsonDecode(encoded) as Map<String, dynamic>;
    switch (j['type']) {
      case 'pong':
        // Old Pong.fromJson requires this field, ignores unknown optional keys.
        j['in_reply_to'] as String;
        // Old sync handler only acts on background_progress (absent here).
        return;
      case 'session_history':
        j['in_reply_to'] as String;
        (j['session_started_at'] as num).toInt();
        j['eos'] as bool;
        final rows = <String>[];
        for (final event in j['events'] as List) {
          (event['ts'] as num).toInt();
          switch (event['type']) {
            case 'agent_message':
              event['in_reply_to'] as String;
              rows.add(event['text'] as String);
            case 'user_input':
              event['id'] as String;
              rows.add(event['text'] as String);
            default:
              _unsupported();
              return;
          }
        }
        history
          ..clear()
          ..addAll(rows);
        return;
      default:
        _unsupported();
    }
  }

  void _unsupported() {
    streaming = '';
    errors.add('unsupported_type');
  }

  // Old MessageRecord assistant projection reads ordinary text only.
  String assistantText(Map<String, dynamic> record) =>
      (record['text'] as String?) ?? '';
}
