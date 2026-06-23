import 'package:cockpit/app/core/env.dart';
import 'package:flutter_modular/flutter_modular.dart';

/// Kernel transversal — módulo **sem `path`** → binds root-owned (vivem o app
/// inteiro, nunca descartados em navegação).
///
/// O único bind realmente cross-feature é o [PiSpawnConfig]: o cockpit injeta
/// para spawnar `pi --mode rpc`, e o settings injeta para o `pi` efêmero do
/// pareamento/revoke. O `SettingsStore`/`SettingsController` são **app-scoped**
/// e construídos no `main` (carregados antes do 1º frame → sem flash de tema),
/// então não entram no grafo aqui.
Module buildCoreModule({required PiSpawnConfig config}) =>
    createModule(register: (c) => c.addInstance<PiSpawnConfig>(config));
