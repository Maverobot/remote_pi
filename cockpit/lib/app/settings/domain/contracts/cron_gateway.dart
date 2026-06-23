import 'package:cockpit/app/settings/domain/entities/cron_job.dart';
import 'package:cockpit/app/settings/domain/exceptions/daemon_error.dart';
import 'package:cockpit/app/core/domain/result.dart';

/// Fronteira do cron de daemons (plan/39): agenda prompts recorrentes num
/// daemon. Mesmo control-plane UDS dos daemons (`~/.pi/remote/supervisor.sock`,
/// ops `cron_*`). Reusa [DaemonError] — é o mesmo supervisor.
///
/// A validação (cron-expr válida, intervalo ≥ 60s, supervisor up) é feita no
/// servidor (`cron_add`) — falhas voltam como [DaemonError] com a mensagem.
abstract class CronGateway {
  Future<Result<List<CronJob>, DaemonError>> listCron();

  Future<Result<void, DaemonError>> addCron({
    required String daemonId,
    required String schedule,
    required String prompt,
    String? tz,
    bool skipIfBusy = true,
    bool wake = false,
    bool catchup = false,
  });

  Future<Result<void, DaemonError>> removeCron(String jobId);

  Future<Result<void, DaemonError>> setCronEnabled(String jobId, bool enabled);

  /// Dispara o job agora (ignora o schedule). Devolve o `result` do disparo.
  Future<Result<String, DaemonError>> runCron(String jobId);

  /// Histórico (`cron.jsonl`), opcionalmente filtrado por job e com tail.
  Future<Result<List<CronLogEntry>, DaemonError>> cronLog({
    String? jobId,
    int? tail,
  });
}
