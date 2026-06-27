import 'dart:convert';
import 'dart:io';

import 'package:cockpit/app/cockpit/domain/contracts/claude_hook_installer.dart';
import 'package:cockpit/app/core/data/setup/remote_pi_resolver.dart';
import 'package:cockpit/app/core/domain/result.dart';
import 'package:flutter/foundation.dart';

/// Implementação do [ClaudeHookInstaller].
///
/// 1. Copia o helper `cockpit-hook` do bundle (`Contents/Resources/`) para um
///    caminho estável fora do bundle (`~/.cockpit/bin/cockpit-hook`) — sobrevive
///    a update/move da app; o `settings.json` aponta para a cópia, não para o
///    bundle. Em dev (sem bundle) reusa uma cópia já presente, se houver.
/// 2. Faz **append idempotente** de um entry marcado (`_cockpit`) em cada evento
///    de hook, sem nunca reescrever a lista (preserva hooks do usuário/iTerm2/
///    plugins). Re-rodar remove o entry antigo nosso e re-adiciona — não duplica.
class ClaudeHookInstallerImpl implements ClaudeHookInstaller {
  ClaudeHookInstallerImpl();

  /// Marcador que identifica entries de nossa autoria (para idempotência/cleanup).
  static const String _marker = '_cockpit';
  static const String _markerValue = 'v1';

  /// Eventos de ciclo de vida que instrumentamos. working: UserPromptSubmit/
  /// PreToolUse/PostToolUse; waiting/idle: Notification; idle: Stop/SessionStart/
  /// SessionEnd. (Mapeamento real mora no `cockpit-hook`.)
  static const List<String> _events = <String>[
    'UserPromptSubmit',
    'PreToolUse',
    'PostToolUse',
    'Notification',
    'Stop',
    'SessionStart',
    'SessionEnd',
  ];

  @override
  Future<Result<void, String>> ensureInstalled() async {
    // Por enquanto só macOS/Linux (helper escreve em /dev/tty, POSIX).
    if (Platform.isWindows) {
      return const Success<void, String>(null);
    }
    final home = remotePiHome();
    if (home == null) {
      return const Failure<void, String>('HOME não resolvido');
    }
    try {
      final helperPath = await _ensureHelper(home);
      if (helperPath == null) {
        return const Failure<void, String>('helper cockpit-hook não encontrado');
      }
      await _installHooks(home: home, helperPath: helperPath);
      return const Success<void, String>(null);
    } catch (e) {
      return Failure<void, String>('$e');
    }
  }

  /// Copia o helper do bundle para `~/.cockpit/bin/cockpit-hook` (recopia se
  /// tamanho difere). Devolve o caminho estável, ou `null` se não há fonte.
  Future<String?> _ensureHelper(String home) async {
    final destDir = Directory('$home/.cockpit/bin');
    final dest = File('${destDir.path}/cockpit-hook');

    final bundled = _bundledHelper();
    if (bundled != null && await bundled.exists()) {
      final srcLen = await bundled.length();
      final upToDate = await dest.exists() && await dest.length() == srcLen;
      if (!upToDate) {
        await destDir.create(recursive: true);
        await bundled.copy(dest.path);
        await _chmodExec(dest.path);
      }
      return dest.path;
    }

    // Dev / sem bundle: usa cópia pré-existente (colocada manualmente).
    if (await dest.exists()) return dest.path;
    return null;
  }

  /// Caminho do helper dentro do `.app` (macOS): a partir do executável Flutter
  /// `…/Contents/MacOS/<app>` sobe para `…/Contents/Resources/cockpit-hook`.
  File? _bundledHelper() {
    try {
      final exe = File(Platform.resolvedExecutable);
      final contents = exe.parent.parent; // Contents/MacOS → Contents
      return File('${contents.path}/Resources/cockpit-hook');
    } catch (_) {
      return null;
    }
  }

  Future<void> _chmodExec(String path) async {
    if (Platform.isWindows) return;
    try {
      await Process.run('chmod', ['+x', path]);
    } catch (_) {
      /* best-effort */
    }
  }

  Future<void> _installHooks({
    required String home,
    required String helperPath,
  }) async {
    final file = File('$home/.claude/settings.json');
    Map<String, dynamic> root = <String, dynamic>{};
    if (await file.exists()) {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map) root = Map<String, dynamic>.from(decoded);
    } else {
      await file.parent.create(recursive: true);
    }

    final hooksRaw = root['hooks'];
    final hooks = hooksRaw is Map
        ? Map<String, dynamic>.from(hooksRaw)
        : <String, dynamic>{};

    final ourGroup = <String, dynamic>{
      'matcher': '',
      'hooks': <Map<String, dynamic>>[
        <String, dynamic>{
          'type': 'command',
          'command': helperPath,
          _marker: _markerValue,
        },
      ],
    };

    var changed = false;
    for (final event in _events) {
      final existing = hooks[event];
      final list = existing is List
          ? List<dynamic>.from(existing)
          : <dynamic>[];
      final before = list.length;
      list.removeWhere(_isOurs); // tira entries antigos nossos
      list.add(Map<String, dynamic>.from(ourGroup));
      // mudou se removeu algo diferente do que readicionamos ou se cresceu
      if (list.length != before || before == 0) changed = true;
      hooks[event] = list;
    }

    root['hooks'] = hooks;
    // Sempre regrava (idempotente no conteúdo lógico; barato).
    await file.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(root)}\n',
    );
    if (kDebugMode && changed) {
      debugPrint('[claude-hook] entries instalados em ${file.path}');
    }
  }

  /// Um matcher-group é nosso se algum hook interno carrega o marcador.
  bool _isOurs(dynamic group) {
    if (group is! Map) return false;
    final inner = group['hooks'];
    if (inner is! List) return false;
    return inner.any((h) => h is Map && h[_marker] == _markerValue);
  }
}
