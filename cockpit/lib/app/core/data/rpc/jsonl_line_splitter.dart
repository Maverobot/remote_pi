import 'dart:async';
import 'dart:convert';

/// Quebra um stream de bytes em linhas JSONL conforme o protocolo do
/// `pi --mode rpc`: **LF (`\n`) é o único delimitador**; um `\r` final é
/// removido (aceita `\r\n`).
///
/// Por que não usar `LineSplitter`: o doc do RPC (rpc.md) avisa que leitores
/// genéricos quebram em separadores Unicode (`U+2028`/`U+2029`), que são
/// válidos *dentro* de strings JSON. Este splitter quebra só em `\n`.
///
/// O `utf8.decoder` (chunked) é aplicado antes, então sequências multibyte
/// partidas entre chunks são montadas corretamente.
class JsonlLineSplitter extends StreamTransformerBase<List<int>, String> {
  const JsonlLineSplitter();

  @override
  Stream<String> bind(Stream<List<int>> stream) async* {
    var buffer = '';
    await for (final text in stream.transform(utf8.decoder)) {
      buffer += text;
      var index = buffer.indexOf('\n');
      while (index != -1) {
        var line = buffer.substring(0, index);
        buffer = buffer.substring(index + 1);
        if (line.endsWith('\r')) {
          line = line.substring(0, line.length - 1);
        }
        if (line.isNotEmpty) yield line;
        index = buffer.indexOf('\n');
      }
    }
    final tail = buffer.endsWith('\r')
        ? buffer.substring(0, buffer.length - 1)
        : buffer;
    if (tail.isNotEmpty) yield tail;
  }
}
