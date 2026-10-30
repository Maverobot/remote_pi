/// Provider-visible text only. Signatures and encrypted reasoning are not data
/// in this model. Revisions belong to a single capture epoch/message identity.
enum ThinkingStatus { streaming, complete, incomplete }

class ThinkingScope {
  final String sessionId;
  final String epoch;
  const ThinkingScope({required this.sessionId, required this.epoch});

  static ThinkingScope? tryFromJson(Object? raw) {
    if (raw is! Map ||
        !thinkingId(raw['session_id']) ||
        !thinkingId(raw['epoch'])) {
      return null;
    }
    return ThinkingScope(
      sessionId: raw['session_id'] as String,
      epoch: raw['epoch'] as String,
    );
  }

  Map<String, Object> toJson() => {'session_id': sessionId, 'epoch': epoch};
  @override
  bool operator ==(Object other) =>
      other is ThinkingScope &&
      other.sessionId == sessionId &&
      other.epoch == epoch;
  @override
  int get hashCode => Object.hash(sessionId, epoch);
}

bool thinkingId(Object? value) => value is String && value.trim().isNotEmpty;
bool thinkingInteger(Object? value) =>
    value is int && value >= 0 && value <= 9007199254740991;

class ThinkingObservation {
  final ThinkingScope scope;
  final String messageId;
  final int revision;
  final ThinkingStatus status;
  final String text;
  final String? runId;
  final bool locallyInterrupted;
  const ThinkingObservation({
    required this.scope,
    required this.messageId,
    required this.revision,
    required this.status,
    required this.text,
    this.runId,
    this.locallyInterrupted = false,
  });

  String get id =>
      'thinking:${Uri.encodeComponent(scope.sessionId)}:${Uri.encodeComponent(scope.epoch)}:${Uri.encodeComponent(messageId)}';
  bool get visible => text.trim().isNotEmpty;
  bool get incomplete =>
      status == ThinkingStatus.incomplete ||
      (status == ThinkingStatus.streaming && locallyInterrupted);
  ThinkingObservation interrupted(bool value) => ThinkingObservation(
    scope: scope,
    messageId: messageId,
    revision: revision,
    status: status,
    text: text,
    runId: runId,
    locallyInterrupted: value,
  );

  static ThinkingObservation? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final scope = ThinkingScope.tryFromJson(raw);
    final revision = raw['revision'];
    final status = switch (raw['status']) {
      'streaming' => ThinkingStatus.streaming,
      'complete' => ThinkingStatus.complete,
      'incomplete' => ThinkingStatus.incomplete,
      _ => null,
    };
    if (scope == null ||
        !thinkingId(raw['message_id']) ||
        !thinkingInteger(revision) ||
        revision == 0 ||
        status == null ||
        raw['text'] is! String ||
        (raw.containsKey('run_id') && !thinkingId(raw['run_id'])) ||
        (raw.containsKey('locally_interrupted') &&
            raw['locally_interrupted'] is! bool)) {
      return null;
    }
    return ThinkingObservation(
      scope: scope,
      messageId: raw['message_id'] as String,
      revision: revision as int,
      status: status,
      text: raw['text'] as String,
      runId: raw['run_id'] as String?,
      locallyInterrupted: raw['locally_interrupted'] == true,
    );
  }

  Map<String, Object> toJson() => {
    ...scope.toJson(),
    'message_id': messageId,
    'revision': revision,
    'status': status.name,
    'text': text,
    'run_id': ?runId,
    'locally_interrupted': locallyInterrupted,
  };
  @override
  bool operator ==(Object other) =>
      other is ThinkingObservation &&
      other.scope == scope &&
      other.messageId == messageId &&
      other.revision == revision &&
      other.status == status &&
      other.text == text &&
      other.runId == runId &&
      other.locallyInterrupted == locallyInterrupted;
  @override
  int get hashCode => Object.hash(
    scope,
    messageId,
    revision,
    status,
    text,
    runId,
    locallyInterrupted,
  );
}
