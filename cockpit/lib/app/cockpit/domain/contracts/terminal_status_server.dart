/// Atualização de status de um `claude` rodando numa aba de terminal, enviada
/// pelo helper `cockpit-hook` (instalado nos hooks do Claude Code) via socket.
class ClaudeStatusUpdate {
  const ClaudeStatusUpdate({
    required this.paneId,
    required this.status,
    this.sessionId,
    this.transcriptPath,
  });

  /// Id da aba (vem do env `COCKPIT_PANE_ID` injetado na PTV — roteamento).
  final String paneId;

  /// `working` | `waiting` | `idle` (wire string).
  final String status;

  /// session_id do claude (pra futura persistência/`--resume`).
  final String? sessionId;

  /// Caminho do transcript `.jsonl` do claude.
  final String? transcriptPath;
}

/// Servidor local (socket Unix) que recebe os updates de status do `cockpit-hook`.
///
/// O Claude roda os hooks **sem terminal controlador**, então não dá pra emitir
/// OSC na PTY (write em `/dev/tty` falha com ENXIO). O helper, em vez disso,
/// conecta neste socket e manda o status; o roteamento pra aba certa vem do
/// `paneId` (env injetado no spawn da PTY).
abstract class TerminalStatusServer {
  /// Caminho do socket (injetado no env do PTY como `COCKPIT_STATUS_SOCK`).
  String get socketPath;

  /// Sobe o servidor; [onUpdate] é chamado a cada status recebido.
  Future<void> start(void Function(ClaudeStatusUpdate update) onUpdate);

  /// Derruba o servidor e remove o socket.
  Future<void> stop();
}
