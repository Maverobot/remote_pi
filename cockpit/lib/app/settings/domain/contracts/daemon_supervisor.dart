import 'package:cockpit/app/settings/domain/entities/daemon_info.dart';
import 'package:cockpit/app/settings/domain/exceptions/daemon_error.dart';
import 'package:cockpit/app/core/domain/result.dart';

/// Fronteira de controle dos "Daemon Agents" (agentes 24/7 sob o
/// `pi-supervisord`).
///
/// Lista/controla via o UDS de controle do supervisor
/// (`~/.pi/remote/supervisor.sock`); cria via o CLI `remote-pi create` (que
/// escreve o config local + registra + sobe). Contrato no domínio; a impl
/// (socket/Process) mora em `data/`.
///
/// ⚠️ `stop`/`restart` por-id dependem de ops novas no supervisor
/// (pi-extension) — até existirem, falham com "unknown op". `startAll`/`stopAll`/
/// `restartAll` e `start` por-id já são suportados hoje.
abstract class DaemonSupervisor {
  /// O supervisor está acessível (sock existe + conecta)?
  Future<bool> isOnline();

  /// Lista os daemons registrados com estado de runtime.
  Future<Result<List<DaemonInfo>, DaemonError>> list();

  Future<Result<void, DaemonError>> start(String id);
  Future<Result<void, DaemonError>> stop(String id);
  Future<Result<void, DaemonError>> restart(String id);

  Future<Result<void, DaemonError>> startAll();
  Future<Result<void, DaemonError>> stopAll();
  Future<Result<void, DaemonError>> restartAll();

  /// Remove o daemon (para o processo + tira do registry).
  Future<Result<void, DaemonError>> unregister(String id);

  /// Registra um novo daemon para [cwd] (`remote-pi create <cwd> [--name]`).
  Future<Result<void, DaemonError>> create(String cwd, {String? name});

  /// Renomeia o agente: atualiza `name` no registry global
  /// `~/.pi/remote/daemons.json` (fonte da verdade). O processo vivo só reflete
  /// o novo nome após um restart (o supervisor injeta o nome no spawn).
  Future<Result<void, DaemonError>> setAgentName(String cwd, String name);

  /// Reinicia o **processo do supervisor** (`pi-supervisord`) — não os daemons.
  /// Necessário pra recarregar código novo do pi-extension (Node não faz
  /// hot-reload). Reinicia todos os daemons junto. Delega ao CLI
  /// `remote-pi restart-supervisor`, que trata o detalhe por SO
  /// (launchctl/systemctl/serviço do Windows).
  Future<Result<void, DaemonError>> restartSupervisor();
}
