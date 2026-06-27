import 'package:cockpit/app/core/domain/result.dart';

/// Instala (idempotente) os hooks do Cockpit no `~/.claude/settings.json` e
/// garante que o helper `cockpit-hook` esteja num caminho estável. Chamado no
/// boot do app (decisão: sem passo de onboarding).
///
/// O helper, instalado nos hooks de ciclo de vida do Claude Code, emite um OSC
/// privado na PTY a cada evento (working/waiting/idle); o `CockpitTerminal`
/// capta e reflete o status na aba + notifica.
abstract class ClaudeHookInstaller {
  /// Garante helper copiado e entries presentes. Idempotente: re-rodar não
  /// duplica nem mexe em hooks de terceiros. Falha é não-fatal (logada).
  Future<Result<void, String>> ensureInstalled();
}
