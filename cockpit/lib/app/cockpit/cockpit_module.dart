import 'dart:io';

import 'package:cockpit/app/cockpit/data/filesystem/app_launcher_impl.dart';
import 'package:cockpit/app/cockpit/data/filesystem/file_reader_impl.dart';
import 'package:cockpit/app/cockpit/data/filesystem/file_searcher_impl.dart';
import 'package:cockpit/app/cockpit/data/filesystem/file_system_reader_impl.dart';
import 'package:cockpit/app/cockpit/data/filesystem/folder_lister_impl.dart';
import 'package:cockpit/app/cockpit/data/filesystem/git_status_reader_impl.dart';
import 'package:cockpit/app/cockpit/data/filesystem/session_history_impl.dart';
import 'package:cockpit/app/cockpit/data/filesystem/worktree_manager_impl.dart';
import 'package:cockpit/app/cockpit/data/repositories/hive_dismissed_update_store.dart';
import 'package:cockpit/app/cockpit/data/repositories/hive_project_repository.dart';
import 'package:cockpit/app/cockpit/data/repositories/hive_workspace_layout_store.dart';
import 'package:cockpit/app/cockpit/data/rpc/pi_rpc_process_factory.dart';
import 'package:cockpit/app/cockpit/data/setup/environment_installer_impl.dart';
import 'package:cockpit/app/cockpit/data/setup/environment_probe_impl.dart';
import 'package:cockpit/app/cockpit/data/setup/system_permissions_impl.dart';
import 'package:cockpit/app/cockpit/data/terminal/pty_terminal_gateway_factory.dart';
import 'package:cockpit/app/cockpit/data/update/update_checker_impl.dart';
import 'package:cockpit/app/cockpit/data/update/url_opener_impl.dart';
import 'package:cockpit/app/cockpit/domain/contracts/app_launcher.dart';
import 'package:cockpit/app/cockpit/domain/contracts/dismissed_update_store.dart';
import 'package:cockpit/app/cockpit/domain/contracts/environment_installer.dart';
import 'package:cockpit/app/cockpit/domain/contracts/environment_probe.dart';
import 'package:cockpit/app/cockpit/domain/contracts/file_reader.dart';
import 'package:cockpit/app/cockpit/domain/contracts/file_searcher.dart';
import 'package:cockpit/app/cockpit/domain/contracts/file_system_reader.dart';
import 'package:cockpit/app/cockpit/domain/contracts/folder_lister.dart';
import 'package:cockpit/app/cockpit/domain/contracts/git_status_reader.dart';
import 'package:cockpit/app/cockpit/domain/contracts/notifier.dart';
import 'package:cockpit/app/cockpit/domain/contracts/project_repository.dart';
import 'package:cockpit/app/cockpit/domain/contracts/rpc_gateway_factory.dart';
import 'package:cockpit/app/cockpit/domain/contracts/session_history.dart';
import 'package:cockpit/app/cockpit/domain/contracts/system_permissions.dart';
import 'package:cockpit/app/cockpit/domain/contracts/terminal_gateway_factory.dart';
import 'package:cockpit/app/cockpit/domain/contracts/update_checker.dart';
import 'package:cockpit/app/cockpit/domain/contracts/url_opener.dart';
import 'package:cockpit/app/cockpit/domain/contracts/workspace_layout_store.dart';
import 'package:cockpit/app/cockpit/domain/contracts/worktree_manager.dart';
import 'package:cockpit/app/cockpit/domain/value_objects/update_target.dart';
import 'package:cockpit/app/cockpit/ui/cockpit_page.dart';
import 'package:cockpit/app/cockpit/ui/viewmodels/cockpit_viewmodel.dart';
import 'package:cockpit/app/cockpit/ui/viewmodels/setup_viewmodel.dart';
import 'package:cockpit/app/cockpit/ui/viewmodels/update_viewmodel.dart';
import 'package:cockpit/app/core/env.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:hive_flutter/hive_flutter.dart';

/// Feature **Cockpit** — o shell (home, `path: '/'`). Registra os binds de infra
/// do shell (filesystem, RPC, terminal, repos, setup, update) e declara a rota
/// `/` com os 3 ViewModels page-scoped.
///
/// As factories `buildCockpitViewModel/buildSetupViewModel/buildUpdateViewModel`
/// (que viviam no antigo `dependencies.dart`) viraram closures em `provide:` —
/// mantendo os `..init()`/`..check()` que rodavam no `create:` do provider.
/// `inject<T>()` resolve cada dependência do grafo do módulo.
///
/// Como o shell fica em `/` e o Settings é **empilhado** por cima (não substitui),
/// a rota `/` nunca deixa a pilha em navegação normal → estes binds
/// feature-scoped vivem o app inteiro na prática.
Module buildCockpitModule({
  required PiSpawnConfig config,
  required Box<dynamic> projectBox,
  required Box<dynamic> layoutBox,
  required Box<dynamic> settingsBox,
  required String appVersion,
  required Notifier notifier,
}) => createModule(
  path: '/',
  register: (c) {
    c
      ..addInstance<ProjectRepository>(HiveProjectRepository(projectBox))
      ..addInstance<WorkspaceLayoutStore>(HiveWorkspaceLayoutStore(layoutBox))
      ..addInstance<DismissedUpdateStore>(HiveDismissedUpdateStore(settingsBox))
      ..addInstance<RpcGatewayFactory>(PiRpcProcessFactory(config))
      ..addInstance<EnvironmentProbe>(EnvironmentProbeImpl(config))
      ..addInstance<EnvironmentInstaller>(EnvironmentInstallerImpl(config))
      ..addInstance<FolderLister>(const FolderListerImpl())
      ..addInstance<FileSystemReader>(const FileSystemReaderImpl())
      ..addInstance<FileReader>(const FileReaderImpl())
      ..addInstance<FileSearcher>(FileSearcherImpl())
      ..addInstance<GitStatusReader>(GitStatusReaderImpl())
      ..addInstance<WorktreeManager>(WorktreeManagerImpl())
      ..addInstance<SessionHistory>(const SessionHistoryImpl())
      ..addInstance<TerminalGatewayFactory>(const PtyTerminalGatewayFactory())
      ..addInstance<AppLauncherGateway>(const AppLauncherImpl())
      ..addInstance<SystemPermissions>(SystemPermissionsImpl())
      ..addInstance<Notifier>(notifier)
      ..addInstance<UpdateChecker>(const UpdateCheckerImpl())
      ..addInstance<UrlOpener>(const UrlOpenerImpl())
      ..addInstance<UpdateTarget>(_updateTarget(appVersion))
      ..route(
        '/',
        // ViewModels page-scoped via tear-off `.new` → o auto_injector resolve o
        // construtor a partir dos binds acima. Os `init()`/`check()` (que antes
        // encadeavam no factory) agora rodam no `CockpitPage.initState`.
        provide: (s) => s
          ..addChangeNotifier<CockpitViewModel>(CockpitViewModel.new)
          ..addChangeNotifier<SetupViewModel>(SetupViewModel.new)
          ..addChangeNotifier<UpdateViewModel>(UpdateViewModel.new),
        child: (context, state) => const CockpitPage(),
      );
  },
);

/// [UpdateTarget] da máquina atual: versão do app + plataforma/formato/arch do
/// manifest. macOS → dmg/universal; Windows → exe/x64; Linux → deb/(arm64|x64).
UpdateTarget _updateTarget(String version) {
  if (Platform.isMacOS) {
    return UpdateTarget(
      version: version,
      platform: 'macos',
      format: 'dmg',
      arch: 'universal',
    );
  }
  if (Platform.isWindows) {
    return UpdateTarget(
      version: version,
      platform: 'windows',
      format: 'exe',
      arch: 'x64',
    );
  }
  final arch = Platform.version.toLowerCase().contains('arm') ? 'arm64' : 'x64';
  return UpdateTarget(
    version: version,
    platform: 'linux',
    format: 'deb',
    arch: arch,
  );
}
