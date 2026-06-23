/// Uso da janela de contexto — de `get_session_stats` (`contextUsage`).
class ContextUsage {
  const ContextUsage({this.tokens, required this.contextWindow, this.percent});

  /// Tokens estimados no contexto atual. `null` logo após compaction.
  final int? tokens;

  /// Tamanho total da janela em tokens.
  final int contextWindow;

  /// Percentual usado na escala **0–100** (ex.: `0.1578` = 0,16%). `null`
  /// logo após compaction, até a próxima resposta do assistant.
  final double? percent;
}
