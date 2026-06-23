/// Lista subpastas de um diretório — para o seletor de "qual pasta dentro do
/// projeto o agente vai atuar". Contrato no domínio; impl (dart:io) em `data/`.
abstract class FolderLister {
  /// Nomes das subpastas imediatas de [root] (sem ocultas), ordenados.
  Future<List<String>> subfolders(String root);
}
