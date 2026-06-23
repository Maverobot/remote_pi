# `lib/app/core/` — kernel transversal

O que é **compartilhado por 2+ features** ou é app-global. Não é uma feature: o
`core_module.dart` é um `createModule` **sem `path`** → seus binds são root-owned
(vivem o app inteiro, nunca descartados).

> **Regra de ouro**: o `core/` **não importa de feature nenhuma**. Features
> importam do `core/`, nunca o contrário. Se algo no core precisar de uma feature,
> ele não é core — mora na feature.

## O que mora aqui

```
core/
├── core_module.dart   # binds root-owned (hoje: PiSpawnConfig)
├── routes.dart        # RoutePaths (consts de path; evita string mágica)
├── env.dart           # PiSpawnConfig (resolve o binário pi + args)
├── app_intents.dart   # ponte global de atalhos (foco do composer)
├── domain/
│   ├── contracts/     # markers: Service, Disposable, UseCase; settings_store
│   ├── entities/      # app_settings (preferências)
│   └── result.dart    # Result<T, E>
├── data/              # utils compartilhados: jsonl_line_splitter, remote_pi_resolver,
│   │                  #   hive_settings_store
│   └── ...
└── ui/
    ├── settings_controller.dart  # APP-SCOPED (tema/fonte) — construído no main,
    │                             #   provido em ModularApp.provide (não em rota)
    ├── themes/        # tema dark; context.colors / context.typo / syntax
    ├── widgets/       # widgets reutilizados por +1 feature (hover_tap, app_menu,
    │                  #   code_highlight, window_controls)
    └── file_icons/    # mapa de ícone por tipo de arquivo
```

## Critério: core vs feature

- Usado por **só uma** feature → vai para a feature (`app/<feature>/...`).
- Usado por **duas ou mais** (ou é app-global) → core.
- Ex.: `SupervisorClientImpl` serve daemons **e** cron (mesma instância sob dois
  contratos) → fica em `settings/data` porque ambos são da feature *settings*; já
  o `SettingsController` (tema lido pelo shell **e** editado em settings) e o
  `PiSpawnConfig` (RPC do cockpit **e** pi efêmero do settings) são core.

## Tema

Toda cor/tipografia vem de `themes/` via `context.colors.<token>` /
`context.typo.<estilo>` (barrel `themes/themes.dart`). Nunca hardcode `Color(0x…)`
ou `TextStyle(fontFamily:…)` em widget.
