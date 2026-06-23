/// Mensagem de uma sessão carregada (de `get_messages`), já no formato do
/// transcript. Versão de domínio das `AgentMessage` do RPC — a `data/` traduz
/// o wire format e a `ui/` mapeia 1:1 para os itens visuais.
sealed class TranscriptMessage {
  const TranscriptMessage();
}

final class TmUser extends TranscriptMessage {
  const TmUser(this.text);
  final String text;
}

final class TmAssistantText extends TranscriptMessage {
  const TmAssistantText(this.text);
  final String text;
}

final class TmThinking extends TranscriptMessage {
  const TmThinking(this.text);
  final String text;
}

/// Tool call já resolvido (resultado preenchido pela `toolResult` correspondente).
final class TmTool extends TranscriptMessage {
  TmTool({required this.callId, required this.name, required this.args});

  final String callId;
  final String name;
  final Map<String, dynamic> args;

  bool done = false;
  bool isError = false;
  String resultText = '';
}
