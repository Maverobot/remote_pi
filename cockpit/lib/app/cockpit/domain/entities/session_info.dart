/// Uma sessão salva do pi (um `.jsonl` em `~/.pi/agent/sessions/<cwd>/`).
class SessionInfo {
  const SessionInfo({
    required this.path,
    required this.id,
    required this.modifiedAt,
    this.title,
  });

  /// Caminho absoluto do arquivo de sessão (usado em `switch_session`).
  final String path;

  /// Id curto da sessão (sufixo do nome do arquivo).
  final String id;

  /// Última modificação (para ordenar + exibir).
  final DateTime modifiedAt;

  /// Rótulo legível da sessão. O pi **não** guarda um nome de sessão, então
  /// derivamos da **primeira mensagem do usuário** (como título de chat).
  /// `null` quando não pedido (`withTitle: false`) ou a sessão está vazia.
  final String? title;
}
