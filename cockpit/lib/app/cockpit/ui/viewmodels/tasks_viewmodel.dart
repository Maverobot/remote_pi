import 'dart:async';

import 'package:cockpit/app/cockpit/domain/contracts/task_discovery.dart';
import 'package:cockpit/app/cockpit/domain/contracts/task_runner_gateway.dart';
import 'package:cockpit/app/cockpit/domain/entities/task_definition.dart';
import 'package:cockpit/app/cockpit/domain/entities/task_run.dart';
import 'package:flutter/foundation.dart';

/// ViewModel page-scoped do subpane de Tasks. Descobre as tasks do projeto
/// selecionado e dirige o ciclo de vida via [TaskRunnerGateway], refletindo o
/// stream de estados vivos. A `ui/` nunca toca `data/` direto.
class TasksViewModel extends ChangeNotifier {
  TasksViewModel(this._discovery, this._runner) {
    _sub = _runner.runs().listen(_onRun);
  }

  final TaskDiscovery _discovery;
  final TaskRunnerGateway _runner;
  StreamSubscription<TaskRun>? _sub;

  String _cwd = '';
  List<TaskDefinition> _tasks = const [];
  bool _loading = false;
  String? _focusedTaskId;
  final _states = <String, TaskRun>{};

  List<TaskDefinition> get tasks => _tasks;
  bool get loading => _loading;

  /// Task cujo output está aberto no terminal embutido (null = nenhum).
  String? get focusedTaskId => _focusedTaskId;

  /// Abre/fecha o terminal de output de uma task (toggle).
  void focus(String taskId) {
    _focusedTaskId = _focusedTaskId == taskId ? null : taskId;
    notifyListeners();
  }

  /// Estado atual de uma task (idle se nunca rodou).
  TaskRun stateOf(String taskId) =>
      _states[taskId] ?? _runner.runOf(taskId);

  /// (Re)carrega as tasks do projeto em [cwd]. No-op se já é o cwd corrente.
  Future<void> loadFor(String cwd) async {
    if (cwd == _cwd) return;
    _cwd = cwd;
    _tasks = const [];
    _focusedTaskId = null;
    _loading = true;
    notifyListeners();
    final found = cwd.isEmpty
        ? const <TaskDefinition>[]
        : await _discovery.discover(cwd);
    if (cwd != _cwd) return; // corrida com outra troca de projeto
    _tasks = found;
    _loading = false;
    notifyListeners();
  }

  Future<void> start(TaskDefinition def, {String? profileName}) =>
      _runner.start(def, profileName: profileName);

  Future<void> stop(String taskId) => _runner.stop(taskId);

  Future<void> restart(String taskId) => _runner.restart(taskId);

  void sendKey(String taskId, String key) => _runner.sendKey(taskId, key);

  void resize(String taskId, int rows, int columns) =>
      _runner.resize(taskId, rows, columns);

  /// Bytes do output de uma task (pra um terminal embutido — passo futuro).
  Stream<List<int>> output(String taskId) => _runner.output(taskId);

  void _onRun(TaskRun run) {
    _states[run.taskId] = run;
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
