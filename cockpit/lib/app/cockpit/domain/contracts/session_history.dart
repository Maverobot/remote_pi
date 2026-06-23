import 'package:cockpit/app/cockpit/domain/entities/session_info.dart';

/// Lista as sessões salvas do pi para uma pasta. Contrato no domínio; a impl
/// (lê `~/.pi/agent/sessions/<cwd-codificado>/`) mora em `data/`.
abstract class SessionHistory {
  /// Sessões da pasta [cwd], mais recentes primeiro. [withTitle] = também lê o
  /// começo de cada `.jsonl` pra derivar o título (1ª mensagem do usuário) —
  /// custa I/O extra, então fica desligado nos caminhos quentes (captura/baseline).
  Future<List<SessionInfo>> sessionsFor(String cwd, {bool withTitle = false});
}
