/// Resultado de um disparo (ou skip) de cron, do log do supervisor.
enum CronResult {
  delivered,
  deliverFailed,
  wokeAndDelivered,
  skippedBusy,
  skippedDown,
  skippedDisabled,
  unknown,
}

CronResult cronResultFromWire(String? raw) => switch (raw) {
  'delivered' => CronResult.delivered,
  'deliver_failed' => CronResult.deliverFailed,
  'woke_and_delivered' => CronResult.wokeAndDelivered,
  'skipped_busy' => CronResult.skippedBusy,
  'skipped_down' => CronResult.skippedDown,
  'skipped_disabled' => CronResult.skippedDisabled,
  _ => CronResult.unknown,
};

/// Um job de cron: prompt recorrente agendado para um daemon (plan/39).
/// Espelha o `CronJobView` do supervisor (`control_protocol.ts`): o job + o
/// `nextRun` calculado.
class CronJob {
  const CronJob({
    required this.id,
    required this.daemonId,
    required this.schedule,
    required this.prompt,
    required this.enabled,
    required this.skipIfBusy,
    required this.wake,
    required this.catchup,
    this.tz,
    this.createdAt,
    this.lastRun,
    this.lastStatus,
    this.nextRun,
  });

  final String id; // "j_<rand>"
  final String daemonId; // id 8-hex do daemon alvo
  final String schedule; // expressão cron
  final String prompt;
  final bool enabled;
  final bool skipIfBusy;
  final bool wake;
  final bool catchup;
  final String? tz;
  final String? createdAt; // ISO
  final String? lastRun; // ISO
  final String? lastStatus; // último CronResult (string crua)
  final String? nextRun; // ISO ou null

  @override
  bool operator ==(Object other) =>
      other is CronJob &&
      other.id == id &&
      other.daemonId == daemonId &&
      other.schedule == schedule &&
      other.prompt == prompt &&
      other.enabled == enabled &&
      other.skipIfBusy == skipIfBusy &&
      other.wake == wake &&
      other.catchup == catchup &&
      other.tz == tz &&
      other.lastRun == lastRun &&
      other.lastStatus == lastStatus &&
      other.nextRun == nextRun;

  @override
  int get hashCode => Object.hash(
    id,
    daemonId,
    schedule,
    prompt,
    enabled,
    skipIfBusy,
    wake,
    catchup,
    tz,
    lastRun,
    lastStatus,
    nextRun,
  );
}

/// Uma linha do log do cron (`cron.jsonl`) — todo disparo E todo skip.
class CronLogEntry {
  const CronLogEntry({
    required this.tsMs,
    required this.jobId,
    required this.daemonId,
    required this.schedule,
    required this.fired,
    required this.result,
    required this.promptPreview,
  });

  final int tsMs; // epoch ms
  final String jobId;
  final String daemonId;
  final String schedule;
  final bool fired;
  final CronResult result;
  final String promptPreview;
}
