import 'package:app/protocol/protocol.dart';

/// Adapt payload-only business fixtures to a successful current-host reply.
/// Protocol rejection tests must send raw frames instead of using this helper.
SessionHistory sdkFullHostReply(
  SessionHistory history,
  String requestId, {
  String? sessionId,
}) => SessionHistory(
  inReplyTo: requestId,
  sessionStartedAt: history.sessionStartedAt,
  events: history.events,
  eos: history.eos,
  roomId: history.roomId ?? 'main',
  historyFormat: 'sdk_full',
  sessionId: history.thinkingHistory?.scope.sessionId ?? sessionId ?? 'S',
  part: 0,
  thinkingHistoryPresent: history.thinkingHistoryPresent,
  thinkingHistory: history.thinkingHistory,
);
