import 'dart:convert';
import 'dart:io';

import 'package:cockpit/domain/contracts/session_history.dart';
import 'package:cockpit/domain/entities/session_info.dart';

/// Lê as sessões salvas do pi de `~/.pi/agent/sessions/<cwd-codificado>/`.
///
/// A pasta de uma sessão segue o **mesmo esquema do pi** (core/session-manager):
/// remove o separador inicial, troca `/`, `\` e `:` por `-`, e envolve em `--…--`
/// (ex.: `/Users/jacob/app` → `--Users-jacob-app--`;
/// `R:\code\orbe` → `--R-code-orbe--`). Cada `.jsonl` é uma sessão.
class SessionHistoryImpl implements SessionHistory {
  const SessionHistoryImpl();

  @override
  Future<List<SessionInfo>> sessionsFor(
    String cwd, {
    bool withTitle = false,
  }) async {
    final dir = Directory('${_sessionsRoot()}/${_encode(cwd)}');
    final sessions = <SessionInfo>[];
    try {
      if (!await dir.exists()) return const <SessionInfo>[];
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File || !entity.path.endsWith('.jsonl')) continue;
        final stat = await entity.stat();
        sessions.add(
          SessionInfo(
            path: entity.path,
            id: _idOf(entity.path),
            modifiedAt: stat.modified,
            title: withTitle ? await _titleOf(entity) : null,
          ),
        );
      }
    } catch (_) {
      // path inválido/ilegível → trata como "sem sessões" em vez de crashar.
      return const <SessionInfo>[];
    }
    sessions.sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
    return sessions;
  }

  /// Título derivado = 1ª mensagem do usuário (o pi não grava nome de sessão).
  /// Lê o `.jsonl` linha a linha e **para** na primeira mensagem `role:user`.
  Future<String?> _titleOf(File file) async {
    try {
      final lines = file
          .openRead()
          .transform(utf8.decoder)
          .transform(const LineSplitter());
      await for (final line in lines) {
        if (line.isEmpty || !line.contains('"user"')) continue;
        final Object? obj = jsonDecode(line);
        if (obj is! Map || obj['type'] != 'message') continue;
        final msg = obj['message'];
        if (msg is! Map || msg['role'] != 'user') continue;
        final text = _textOf(
          msg['content'],
        ).trim().replaceAll(RegExp(r'\s+'), ' ');
        if (text.isEmpty) continue;
        return text.length > 100 ? '${text.substring(0, 100)}…' : text;
      }
    } catch (_) {
      // arquivo ilegível/corrompido → sem título
    }
    return null;
  }

  /// Extrai o texto do `content` de uma mensagem (string ou lista de partes).
  String _textOf(Object? content) {
    if (content is String) return content;
    if (content is List) {
      final parts = <String>[];
      for (final p in content) {
        if (p is String) {
          parts.add(p);
        } else if (p is Map && p['type'] == 'text' && p['text'] is String) {
          parts.add(p['text'] as String);
        }
      }
      return parts.join(' ');
    }
    return '';
  }

  String _sessionsRoot() {
    // Windows não seta HOME; o equivalente é USERPROFILE.
    final home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    final agentDir =
        Platform.environment['PI_CODING_AGENT_DIR'] ?? '$home/.pi/agent';
    return '$agentDir/sessions';
  }

  /// Codifica o cwd no nome de pasta do pi. Espelha
  /// `core/session-manager.js`: `--${cwd.replace(/^[/\\]/,'').replace(/[/\\:]/g,'-')}--`.
  /// Sem isso, no Windows o `:`/`\` do path (ex.: `R:\code`) entram crus e geram
  /// um nome de diretório inválido.
  String _encode(String cwd) {
    final stripped = cwd.replaceFirst(RegExp(r'^[/\\]'), '');
    final slug = stripped.replaceAll(RegExp(r'[/\\:]'), '-');
    return '--$slug--';
  }

  /// Sufixo uuid do nome do arquivo `<timestamp>_<uuid>.jsonl`. Aceita `/` e `\`
  /// como separador (Windows).
  String _idOf(String path) {
    final name = path.split(RegExp(r'[/\\]')).last.replaceAll('.jsonl', '');
    final underscore = name.lastIndexOf('_');
    return underscore == -1 ? name : name.substring(underscore + 1);
  }
}
