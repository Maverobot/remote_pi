/// Estado git de um projeto (workspace). Só o essencial pra rail: branch atual
/// e quantos arquivos estão sujos (modificados/staged/untracked).
class GitInfo {
  const GitInfo({required this.branch, required this.dirtyCount});

  /// Branch atual (ou short SHA se detached HEAD).
  final String branch;

  /// Nº de arquivos com mudança (`git status --porcelain`). 0 = árvore limpa.
  final int dirtyCount;

  bool get isDirty => dirtyCount > 0;
}
