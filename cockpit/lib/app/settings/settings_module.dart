import 'package:cockpit/app/settings/data/daemon/supervisor_client_impl.dart';
import 'package:cockpit/app/settings/data/relay/pairing_gateway_impl.dart';
import 'package:cockpit/app/settings/data/relay/relay_gateway_impl.dart';
import 'package:cockpit/app/settings/data/relay/revoke_gateway_impl.dart';
import 'package:cockpit/app/settings/domain/contracts/cron_gateway.dart';
import 'package:cockpit/app/settings/domain/contracts/daemon_supervisor.dart';
import 'package:cockpit/app/settings/domain/contracts/pairing_gateway.dart';
import 'package:cockpit/app/settings/domain/contracts/relay_gateway.dart';
import 'package:cockpit/app/settings/domain/contracts/revoke_gateway.dart';
import 'package:cockpit/app/settings/ui/connectivity_viewmodel.dart';
import 'package:cockpit/app/settings/ui/cron_viewmodel.dart';
import 'package:cockpit/app/settings/ui/daemons_viewmodel.dart';
import 'package:cockpit/app/settings/ui/settings_page.dart';
import 'package:flutter_modular/flutter_modular.dart';

/// Feature **Configurações** — `path: '/settings'` (rota empilhada por cima do
/// shell via `pushNamed`; o shell continua na base da pilha). Cobre Conectividade,
/// Daemon Agents e Agendamentos (cron).
///
/// O [SupervisorClientImpl] é **uma instância** sob dois contratos
/// ([DaemonSupervisor] + [CronGateway]) — mesmo control-plane UDS do
/// `pi-supervisord`. Os ViewModels são page-scoped (`provide`): nascem ao abrir a
/// tela e morrem (`dispose`) ao fechar. As factories de pareamento/revoke criam
/// um `pi --mode rpc` efêmero por dialog (recebem o PiSpawnConfig do core).
Module buildSettingsModule() => createModule(
  path: '/settings',
  register: (c) {
    final supervisor = SupervisorClientImpl();
    c
      ..addInstance<RelayGateway>(RelayGatewayImpl())
      ..addInstance<DaemonSupervisor>(supervisor)
      ..addInstance<CronGateway>(supervisor)
      ..route(
        '/',
        transition: TransitionType.fade,
        provide: (s) => s
          ..add<PairingGatewayFactory>(PairingGatewayFactoryImpl.new)
          ..add<RevokeGatewayFactory>(RevokeGatewayFactoryImpl.new)
          ..addChangeNotifier<ConnectivityViewModel>(ConnectivityViewModel.new)
          ..addChangeNotifier<DaemonsViewModel>(DaemonsViewModel.new)
          ..addChangeNotifier<CronViewModel>(CronViewModel.new),
        child: (context, state) => const SettingsPage(),
      );
  },
);
