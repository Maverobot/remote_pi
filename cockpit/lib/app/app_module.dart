import 'package:cockpit/app/cockpit/cockpit_module.dart';
import 'package:cockpit/app/core/core_module.dart';
import 'package:cockpit/app/core/env.dart';
import 'package:cockpit/app/cockpit/domain/contracts/notifier.dart';
import 'package:cockpit/app/settings/settings_module.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:hive_flutter/hive_flutter.dart';

/// Módulo raiz — **só composição**. É o mapa de acoplamento do app: quais módulos
/// existem e como se conectam. Cada submódulo declara seu próprio `path` (ou a
/// ausência dele, no caso do core), então aqui é só `module(...)`.
///
/// Construído **uma vez** no `main` (com os valores resolvidos no bootstrap async)
/// — dedup por identidade preservado.
Module buildAppModule({
  required PiSpawnConfig config,
  required Box<dynamic> projectBox,
  required Box<dynamic> layoutBox,
  required Box<dynamic> settingsBox,
  required String appVersion,
  required Notifier notifier,
}) {
  final core = buildCoreModule(config: config);
  final cockpit = buildCockpitModule(
    config: config,
    projectBox: projectBox,
    layoutBox: layoutBox,
    settingsBox: settingsBox,
    appVersion: appVersion,
    notifier: notifier,
  );
  final settings = buildSettingsModule();
  return createModule(
    register: (c) => c
      ..module(core)
      ..module(cockpit)
      ..module(settings),
  );
}
