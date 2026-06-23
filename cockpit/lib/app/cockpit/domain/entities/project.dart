/// Uma pasta que o usuário salvou como projeto (workspace). Os workspaces raiz
/// são persistidos via Hive; as **worktrees** (forks) são `Project`s de runtime
/// com [parentId] preenchido, derivados do git e **não** persistidos (a
/// existência mora no git — ver `plan/42`, decisões 1 e 4).
/// Agentes do Cockpit atuam em subpastas de [path].
class Project {
  const Project({
    required this.id,
    required this.name,
    required this.path,
    required this.colorValue,
    required this.createdAt,
    this.parentId,
    this.order = 0,
    this.imagePath,
  });

  /// Sentinela do [copyWith] para distinguir "não mexer em [imagePath]" de
  /// "limpar [imagePath] (passar null)".
  static const Object unchanged = Object();

  final String id;

  /// Nome de exibição (por padrão, o basename de [path]).
  final String name;

  /// Caminho absoluto da raiz do projeto.
  final String path;

  /// Cor do avatar (ARGB), atribuída na criação.
  final int colorValue;

  final DateTime createdAt;

  /// `null` para um workspace raiz; o id do workspace pai quando este `Project`
  /// é uma worktree (fork). Define o aninhamento no rail.
  final String? parentId;

  /// Posição manual no rail (drag-drop de workspaces). Só relevante para
  /// workspaces raiz — worktrees herdam a do pai e aninham embaixo dele.
  /// Persistido; default `0` (dados antigos caem na ordem por [createdAt]).
  final int order;

  /// Caminho absoluto de uma imagem (PNG/JPG) que substitui o avatar
  /// quadrado-com-inicial no rail. `null` = sem imagem. Persistido; se o arquivo
  /// sumir/ilegível, a UI cai num placeholder de erro (ver `WorkspaceAvatar`).
  final String? imagePath;

  /// `true` quando este `Project` é uma worktree de outro workspace.
  bool get isWorktree => parentId != null;

  /// Inicial pro avatar da rail.
  String get initial => name.isNotEmpty ? name[0].toUpperCase() : '?';

  Project copyWith({
    String? name,
    int? colorValue,
    int? order,
    Object? imagePath = unchanged,
  }) => Project(
    id: id,
    name: name ?? this.name,
    path: path,
    colorValue: colorValue ?? this.colorValue,
    createdAt: createdAt,
    parentId: parentId,
    order: order ?? this.order,
    imagePath: imagePath == unchanged ? this.imagePath : imagePath as String?,
  );

  @override
  bool operator ==(Object other) => other is Project && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
