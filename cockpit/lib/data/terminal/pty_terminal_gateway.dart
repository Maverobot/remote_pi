import 'dart:io';
import 'dart:typed_data';

import 'package:cockpit/domain/contracts/terminal_gateway.dart';
import 'package:kyroon_pty/kyroon_pty.dart';

/// PTY nativo via `kyroon_pty`. Roda o shell real do SO num pseudo-terminal.
class PtyTerminalGateway implements TerminalGateway {
  Pty? _pty;

  @override
  void start({
    required String workingDirectory,
    int rows = 25,
    int columns = 80,
  }) {
    _pty = Pty.start(
      _shell(),
      workingDirectory: workingDirectory.isEmpty ? null : workingDirectory,
      environment: Map<String, String>.of(Platform.environment),
      rows: rows,
      columns: columns,
    );
  }

  @override
  Stream<List<int>> get output =>
      _pty?.output ?? const Stream<List<int>>.empty();

  @override
  void write(List<int> data) =>
      _pty?.write(data is Uint8List ? data : Uint8List.fromList(data));

  @override
  void resize(int rows, int columns) => _pty?.resize(rows, columns);

  @override
  Future<void> kill() async {
    try {
      _pty?.kill();
    } catch (_) {
      // já encerrado.
    }
  }

  /// Shell por plataforma.
  String _shell() {
    if (Platform.isWindows) return 'powershell.exe';
    return Platform.environment['SHELL'] ?? '/bin/zsh';
  }
}
