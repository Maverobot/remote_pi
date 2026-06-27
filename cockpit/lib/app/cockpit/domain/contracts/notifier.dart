/// Notificações nativas do SO. Contrato no domínio; a impl (plugin) mora em
/// `data/notifications/`.
abstract class Notifier {
  /// Inicializa o backend (pede permissão no boot).
  Future<void> init();

  /// Notifica que um agente terminou um turno.
  Future<void> agentFinished({
    required String agentName,
    required String workspace,
  });

  /// Toca um som curto de "turno terminou" (chime in-app). Usado quando a janela
  /// está focada — chama atenção sem banner do SO. Distinto do som da
  /// notificação do SO (que toca só com a janela desfocada).
  Future<void> playTurnChime();
}
