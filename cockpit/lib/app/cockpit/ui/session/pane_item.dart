import 'package:flutter/foundation.dart';

/// Base de uma aba do multiplexador — um agente (`AgentSession`) ou um terminal
/// (`TerminalSession`). A VM guarda todas as abas como [PaneItem]; a UI decide
/// como renderizar pelo tipo concreto.
abstract class PaneItem extends ChangeNotifier {
  String get id;
  String get projectId;
  String get title;
  String get workingDirectory;

  /// `true` enquanto a aba está processando trabalho (acende o spinner na aba).
  /// Default `false`; agentes e terminais sobrescrevem.
  bool get isWorking => false;

  /// Resultado novo não visto; default `false`. Agentes e terminais (com claude)
  /// sobrescrevem.
  bool get unseenFinish => false;

  /// Marca/limpa o badge de "resultado não visto". No-op por default.
  void markUnseen() {}
  void clearUnseen() {}
}
