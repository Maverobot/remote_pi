/// Pseudo-terminal nativo (PTY) rodando um shell. Contrato no domínio; a impl
/// (`data/terminal/`) usa `flutter_pty` (forkpty no macOS/Linux, ConPTY no
/// Windows). A `ui/` (TerminalSession) só conhece esta interface.
abstract class TerminalGateway {
  /// Sobe o shell num PTY na pasta [workingDirectory].
  void start({
    required String workingDirectory,
    int rows = 25,
    int columns = 80,
  });

  /// Bytes do stdout/stderr do shell.
  Stream<List<int>> get output;

  /// Escreve no stdin do shell (teclado).
  void write(List<int> data);

  /// Redimensiona o PTY.
  void resize(int rows, int columns);

  /// Mata o shell limpo (sem órfão).
  Future<void> kill();
}
