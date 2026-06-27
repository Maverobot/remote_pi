import 'dart:convert';
import 'dart:io';

import 'package:cockpit/app/cockpit/domain/contracts/terminal_status_server.dart';
import 'package:cockpit/app/core/data/setup/remote_pi_resolver.dart';
import 'package:flutter/foundation.dart';

/// [TerminalStatusServer] sobre socket Unix em `~/.cockpit/status.sock`.
///
/// Cada conexão do `cockpit-hook` manda **uma linha JSON**
/// (`{paneId, st, sid, tx}`) e fecha. Parseamos e repassamos via callback.
class TerminalStatusServerImpl implements TerminalStatusServer {
  TerminalStatusServerImpl();

  ServerSocket? _server;
  void Function(ClaudeStatusUpdate update)? _onUpdate;

  @override
  String get socketPath {
    final home = remotePiHome() ?? Directory.systemTemp.path;
    return '$home/.cockpit/status.sock';
  }

  @override
  Future<void> start(void Function(ClaudeStatusUpdate update) onUpdate) async {
    if (_server != null) return;
    // Sem suporte a socket Unix no Windows (fase macOS/Linux).
    if (Platform.isWindows) return;
    _onUpdate = onUpdate;

    final path = socketPath;
    try {
      final file = File(path);
      await file.parent.create(recursive: true);
      // Remove socket órfão do ciclo anterior (bind falha se já existe).
      if (await file.exists()) await file.delete();

      final address = InternetAddress(path, type: InternetAddressType.unix);
      _server = await ServerSocket.bind(address, 0);
      _server!.listen(_handleConnection, onError: (_) {});
    } catch (e) {
      if (kDebugMode) debugPrint('[status-server] bind falhou: $e');
    }
  }

  void _handleConnection(Socket socket) {
    // Acumula a linha; a conexão é curta (um JSON + close).
    final buffer = StringBuffer();
    socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .listen(
          buffer.write,
          onDone: () {
            _dispatch(buffer.toString());
            socket.destroy();
          },
          onError: (_) => socket.destroy(),
          cancelOnError: true,
        );
  }

  void _dispatch(String raw) {
    final line = raw.trim();
    if (line.isEmpty) return;
    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map) return;
      final paneId = (decoded['paneId'] ?? '').toString();
      final status = (decoded['st'] ?? '').toString();
      if (paneId.isEmpty || status.isEmpty) return;
      final sid = (decoded['sid'] ?? '').toString();
      final tx = (decoded['tx'] ?? '').toString();
      _onUpdate?.call(
        ClaudeStatusUpdate(
          paneId: paneId,
          status: status,
          sessionId: sid.isEmpty ? null : sid,
          transcriptPath: tx.isEmpty ? null : tx,
        ),
      );
    } catch (_) {
      /* linha malformada: ignora */
    }
  }

  @override
  Future<void> stop() async {
    await _server?.close();
    _server = null;
    _onUpdate = null;
    try {
      final file = File(socketPath);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}
