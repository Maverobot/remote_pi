/// Persiste o layout do multiplexador de um projeto (árvore de panes + os
/// descritores de cada aba) como um **documento JSON opaco**, keyed por
/// `projectId`.
///
/// A *forma* do documento é detalhe da `ui/` (quem conhece `PaneNode` e as
/// sessões) — aqui é só um blob versionado que a `data/` guarda e devolve. Por
/// isso o contrato trafega `Map<String, dynamic>` em vez de um tipo do domínio:
/// o store não interpreta o conteúdo, só o persiste.
abstract class WorkspaceLayoutStore {
  /// Documento salvo do projeto, ou `null` se nunca foi salvo.
  Future<Map<String, dynamic>?> load(String projectId);

  /// Salva (sobrescreve) o documento do projeto.
  Future<void> save(String projectId, Map<String, dynamic> document);

  /// Remove o documento do projeto (ao deletar o projeto).
  Future<void> remove(String projectId);
}
