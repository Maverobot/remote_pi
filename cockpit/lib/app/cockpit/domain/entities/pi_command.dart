/// Um slash command disponível no agente (vem de `get_commands`). No pi, os
/// comandos são providos por **extensions**; o `name` pode ter espaço (ex.:
/// `remote-pi setup`). Invocado mandando `/<name>` como prompt.
class PiCommand {
  const PiCommand({required this.name, required this.description});

  final String name;
  final String description;
}
