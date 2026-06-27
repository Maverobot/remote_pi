// Helper instalado nos hooks do Claude Code (~/.claude/settings.json) pelo
// `ClaudeHookInstaller` do Cockpit. O Claude o invoca a cada evento de ciclo de
// vida, passando um JSON pelo stdin. Traduzimos o evento num status de turno
// (working / waiting / idle) e mandamos pro Cockpit por um **socket Unix**.
//
// Por que socket e não OSC na PTY: o Claude roda os hooks SEM terminal
// controlador (escrever em /dev/tty falha com ENXIO). Então o app injeta no env
// da PTY o `COCKPIT_PANE_ID` (roteamento) e o `COCKPIT_STATUS_SOCK` (caminho do
// socket); o hook herda os dois e reporta o status por ali. Sessões `claude`
// fora do Cockpit não têm essas envs → o hook é no-op (gate natural).
//
// Compilar: dart compile exe tool/cockpit_hook.dart -o <dest>/cockpit-hook
// NÃO escreve no stdout (participa do protocolo de hook). Nunca falha barulhento.

import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  try {
    final paneId = Platform.environment['COCKPIT_PANE_ID'];
    final sock = Platform.environment['COCKPIT_STATUS_SOCK'];
    if (paneId == null || paneId.isEmpty || sock == null || sock.isEmpty) {
      return; // não é uma sessão hospedada pelo Cockpit
    }

    final raw = await stdin.transform(utf8.decoder).join();
    if (raw.trim().isEmpty) return;
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return;

    final event = (decoded['hook_event_name'] ?? '').toString();
    final status = _statusFor(event, decoded);
    if (status == null) return; // evento que não nos interessa

    final payload = jsonEncode(<String, dynamic>{
      'paneId': paneId,
      'st': status,
      'sid': (decoded['session_id'] ?? '').toString(),
      'tx': (decoded['transcript_path'] ?? '').toString(),
    });

    final socket = await Socket.connect(
      InternetAddress(sock, type: InternetAddressType.unix),
      0,
    );
    socket.add(utf8.encode('$payload\n'));
    await socket.flush();
    await socket.close();
    socket.destroy();
  } catch (_) {
    // Silencioso de propósito: não atrapalhar o turno do claude.
  }
}

/// Mapeia o evento de hook do Claude Code num status de turno, ou `null` se o
/// evento não deve mover o indicador.
String? _statusFor(String event, Map<dynamic, dynamic> json) {
  switch (event) {
    case 'UserPromptSubmit':
    case 'PreToolUse':
    case 'PostToolUse':
      return 'working';
    case 'Notification':
      // Notification cobre "precisa de aprovação" e "ocioso esperando input".
      final hint = '${json['notification_type'] ?? ''} ${json['message'] ?? ''}'
          .toLowerCase();
      return hint.contains('idle') ? 'idle' : 'waiting';
    case 'Stop':
    case 'SessionStart':
    case 'SessionEnd':
      return 'idle';
    default:
      return null;
  }
}
