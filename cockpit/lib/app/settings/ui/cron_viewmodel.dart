import 'package:cockpit/app/settings/domain/contracts/cron_gateway.dart';
import 'package:cockpit/app/settings/domain/contracts/daemon_supervisor.dart';
import 'package:cockpit/app/settings/domain/entities/cron_job.dart';
import 'package:cockpit/app/settings/domain/entities/daemon_info.dart';
import 'package:cockpit/app/settings/domain/exceptions/daemon_error.dart';
import 'package:cockpit/app/core/domain/result.dart';
import 'package:flutter/foundation.dart';

enum CronLoad { idle, loading, ready, error }

/// Estado da aba **Agendamentos**: jobs de cron (plan/39) + lista de daemons
/// (pra resolver nomes e popular o dropdown do "criar"). Mesmo control-plane
/// UDS dos daemons. Carrega sob demanda; cada ação recarrega.
class CronViewModel extends ChangeNotifier {
  CronViewModel(this._cron, this._supervisor);

  final CronGateway _cron;
  final DaemonSupervisor _supervisor;

  CronLoad load = CronLoad.idle;
  bool online = false;
  List<CronJob> jobs = const <CronJob>[];
  List<DaemonInfo> daemons = const <DaemonInfo>[];
  String? error; // falha ao listar jobs
  String? actionError; // falha da última ação

  final Set<String> _busy = <String>{};

  bool _disposed = false;

  bool isBusy(String id) => _busy.contains(id);
  bool get anyBusy => _busy.isNotEmpty;
  bool get hasDaemons => daemons.isNotEmpty;

  /// Refresh silencioso (polling): só recarrega se estiver ocioso, sem piscar
  /// o spinner de "primeira carga".
  Future<void> refreshQuiet() async {
    if (anyBusy || load == CronLoad.loading) return;
    await reload();
  }

  /// Nome do daemon alvo de um job (resolve pela lista; fallback ao id).
  String daemonName(String daemonId) {
    for (final d in daemons) {
      if (d.id == daemonId) return d.name.isEmpty ? d.id : d.name;
    }
    return daemonId;
  }

  Future<void> reload() async {
    load = CronLoad.loading;
    error = null;
    _notify();

    online = await _supervisor.isOnline();
    if (!online) {
      jobs = const <CronJob>[];
      daemons = const <DaemonInfo>[];
      load = CronLoad.ready;
      _notify();
      return;
    }

    final daemonsResult = await _supervisor.list();
    daemonsResult.fold((d) => daemons = d, (_) {});

    final jobsResult = await _cron.listCron();
    jobsResult.fold(
      (j) {
        jobs = j;
        load = CronLoad.ready;
      },
      (e) {
        error = e.message;
        load = CronLoad.error;
      },
    );
    _notify();
  }

  Future<void> setEnabled(CronJob job, bool enabled) =>
      _action(job.id, () => _cron.setCronEnabled(job.id, enabled));

  Future<void> remove(CronJob job) =>
      _action(job.id, () => _cron.removeCron(job.id));

  Future<void> run(CronJob job) => _action(job.id, () async {
    final r = await _cron.runCron(job.id);
    return r.fold(
      (_) => const Success<void, DaemonError>(null),
      (e) => Failure<void, DaemonError>(e),
    );
  });

  /// Cria um job. Retorna `true` no sucesso (o dialog fecha).
  Future<bool> create({
    required String daemonId,
    required String schedule,
    required String prompt,
    String? tz,
    bool skipIfBusy = true,
    bool wake = false,
    bool catchup = false,
  }) async {
    actionError = null;
    _notify();
    final result = await _cron.addCron(
      daemonId: daemonId,
      schedule: schedule,
      prompt: prompt,
      tz: tz,
      skipIfBusy: skipIfBusy,
      wake: wake,
      catchup: catchup,
    );
    final ok = result.fold((_) => true, (e) {
      actionError = e.message;
      return false;
    });
    if (ok) await reload();
    return ok;
  }

  /// Busca o log (`cron.jsonl`); `null` em falha (com [actionError] setado).
  Future<List<CronLogEntry>?> fetchLog({String? jobId}) async {
    final result = await _cron.cronLog(jobId: jobId, tail: 50);
    return result.fold((list) => list, (e) {
      actionError = e.message;
      _notify();
      return null;
    });
  }

  Future<void> _action(
    String id,
    Future<Result<void, DaemonError>> Function() op,
  ) async {
    if (_busy.contains(id)) return;
    _busy.add(id);
    actionError = null;
    _notify();
    final result = await op();
    result.fold((_) {}, (e) => actionError = e.message);
    _busy.remove(id);
    _notify();
    await reload();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
