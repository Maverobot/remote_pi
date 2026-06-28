import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cockpit/app/cockpit/domain/entities/task_definition.dart';
import 'package:cockpit/app/cockpit/domain/entities/task_run.dart';
import 'package:cockpit/app/cockpit/ui/viewmodels/tasks_viewmodel.dart';
import 'package:cockpit/app/cockpit/ui/widgets/terminal_pane.dart';
import 'package:cockpit/app/core/ui/themes/terminal_theme.dart';
import 'package:cockpit/app/core/ui/themes/themes.dart';
import 'package:cockpit/app/core/ui/widgets/hover_tap.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:xterm/xterm.dart';

/// Subpane de Tasks na coluna direita (abaixo da árvore de arquivos). Lista as
/// tasks detectadas do projeto com badge de estado e controles de ciclo de vida
/// **dirigidos por dados** — botões vêm dos [InteractiveKey] da task, sem
/// nenhum `if (flutter)` aqui.
class TasksPanel extends StatefulWidget {
  const TasksPanel({super.key, required this.cwd});

  /// Pasta do projeto selecionado. Trocar dispara nova descoberta.
  final String cwd;

  @override
  State<TasksPanel> createState() => _TasksPanelState();
}

class _TasksPanelState extends State<TasksPanel> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<TasksViewModel>().loadFor(widget.cwd);
    });
  }

  @override
  void didUpdateWidget(covariant TasksPanel old) {
    super.didUpdateWidget(old);
    if (old.cwd != widget.cwd) {
      context.read<TasksViewModel>().loadFor(widget.cwd);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final vm = context.watch<TasksViewModel>();

    return Container(
      decoration: BoxDecoration(
        color: colors.panel,
        border: Border(top: BorderSide(color: colors.border)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(context, vm),
          if (vm.tasks.isEmpty && !vm.loading)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
              child: Text(
                'Nenhuma task detectada neste projeto.',
                style: context.typo.label.copyWith(color: colors.text3),
              ),
            )
          else
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.only(bottom: 6),
                children: [
                  for (final def in vm.tasks)
                    _TaskRow(
                      def: def,
                      run: vm.stateOf(def.id),
                      selected: vm.focusedTaskId == def.id,
                      onTap: () => vm.focus(def.id),
                      onStart: () => vm.start(def),
                      onStop: () => vm.stop(def.id),
                      onRestart: () => vm.restart(def.id),
                      onKey: (k) => vm.sendKey(def.id, k),
                    ),
                ],
              ),
            ),
          _outputTerminal(context, vm),
        ],
      ),
    );
  }

  /// Terminal embutido da task focada — só aparece se ela está viva (tem PTY).
  Widget _outputTerminal(BuildContext context, TasksViewModel vm) {
    final fid = vm.focusedTaskId;
    if (fid == null) return const SizedBox.shrink();
    final run = vm.stateOf(fid);
    if (!run.isActive) return const SizedBox.shrink();
    return Container(
      height: 260,
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: context.colors.border)),
      ),
      // Key por (taskId, pid): um run novo (restart) remonta o terminal limpo.
      child: _TaskTerminal(
        key: ValueKey('$fid:${run.pid}'),
        vm: vm,
        taskId: fid,
      ),
    );
  }

  Widget _header(BuildContext context, TasksViewModel vm) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 6, 6),
      child: Row(
        children: [
          Text(
            'TASKS',
            style: context.typo.label.copyWith(
              color: colors.text3,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.6,
            ),
          ),
          const SizedBox(width: 6),
          if (vm.loading)
            SizedBox(
              width: 10,
              height: 10,
              child: CircularProgressIndicator(
                strokeWidth: 1.4,
                color: colors.text3,
              ),
            ),
          const Spacer(),
        ],
      ),
    );
  }
}

class _TaskRow extends StatelessWidget {
  const _TaskRow({
    required this.def,
    required this.run,
    required this.selected,
    required this.onTap,
    required this.onStart,
    required this.onStop,
    required this.onRestart,
    required this.onKey,
  });

  final TaskDefinition def;
  final TaskRun run;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final VoidCallback onRestart;
  final void Function(String key) onKey;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final active = run.isActive;

    return Container(
      color: selected ? colors.accent.withValues(alpha: 0.10) : null,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      child: Row(
        children: [
          _StatusDot(status: run.status),
          const SizedBox(width: 8),
          Expanded(
            child: HoverTap(
              onTap: onTap,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    def.label,
                    style: context.typo.label.copyWith(color: colors.text),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    '${def.command} ${def.args.join(' ')}',
                    style: context.typo.mono.copyWith(
                      fontSize: 10,
                      color: colors.text3,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ),
          if (active) ...[
            for (final k in def.interactiveKeys.where((k) => k.primary))
              _IconAction(
                tooltip: "${k.label} (envia '${k.key}')",
                icon: _iconFor(k.icon),
                fallback: k.key,
                onTap: () => onKey(k.key),
              ),
            for (final k in def.interactiveKeys.where((k) => !k.primary))
              _IconAction(
                tooltip: "${k.label} (envia '${k.key}')",
                fallback: k.key,
                onTap: () => onKey(k.key),
              ),
            _IconAction(
              tooltip: 'Reiniciar',
              icon: Icons.restart_alt,
              onTap: onRestart,
            ),
            _IconAction(
              tooltip: 'Parar',
              icon: Icons.stop,
              color: colors.error,
              onTap: onStop,
            ),
          ] else
            _IconAction(
              tooltip: 'Rodar',
              icon: Icons.play_arrow,
              color: colors.online,
              onTap: onStart,
            ),
        ],
      ),
    );
  }

  IconData? _iconFor(String? token) => switch (token) {
    'refresh' => Icons.refresh,
    'restart' => Icons.restart_alt,
    'stop' => Icons.stop,
    _ => null,
  };
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.status});
  final TaskRunStatus status;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final color = switch (status) {
      TaskRunStatus.idle => colors.text4,
      TaskRunStatus.building => colors.warn,
      TaskRunStatus.running => colors.accent,
      TaskRunStatus.success => colors.online,
      TaskRunStatus.failed => colors.error,
      TaskRunStatus.stopped => colors.text3,
    };
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

class _IconAction extends StatelessWidget {
  const _IconAction({
    required this.tooltip,
    required this.onTap,
    this.icon,
    this.fallback,
    this.color,
  });

  final String tooltip;
  final VoidCallback onTap;
  final IconData? icon;
  final String? fallback;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Tooltip(
      tooltip: (context) => TooltipContainer(child: Text(tooltip)),
      child: HoverTap(
        borderRadius: BorderRadius.circular(5),
        onTap: onTap,
        child: SizedBox(
          width: 24,
          height: 24,
          child: icon != null
              ? Icon(icon, size: 15, color: color ?? colors.text2)
              : Center(
                  child: Text(
                    fallback ?? '?',
                    style: context.typo.mono.copyWith(
                      fontSize: 11,
                      color: color ?? colors.text2,
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}

/// Terminal embutido que espelha o output ao vivo de uma task num emulador
/// xterm (mesmo `CockpitTerminal`/`TerminalPane` das abas de shell). Liga o
/// stream de bytes do runner ao terminal e devolve o teclado via `sendKey`
/// (digitar 'r' no `flutter run` funciona igual aos botões). A `Key` por
/// (taskId, pid) garante terminal limpo a cada novo run.
class _TaskTerminal extends StatefulWidget {
  const _TaskTerminal({
    super.key,
    required this.vm,
    required this.taskId,
  });

  final TasksViewModel vm;
  final String taskId;

  @override
  State<_TaskTerminal> createState() => _TaskTerminalState();
}

class _TaskTerminalState extends State<_TaskTerminal> {
  late final Terminal _terminal;
  final _focus = FocusNode();
  StreamSubscription<String>? _sub;

  @override
  void initState() {
    super.initState();
    _terminal = Terminal(maxLines: 5000);
    _terminal.onOutput = (data) => widget.vm.sendKey(widget.taskId, data);
    _terminal.onResize = (w, h, pw, ph) =>
        widget.vm.resize(widget.taskId, h, w);
    _sub = widget.vm
        .output(widget.taskId)
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(_terminal.write);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 0, 6),
      child: TerminalPane(
        terminal: _terminal,
        focusNode: _focus,
        hardwareKeyboardOnly: Platform.isWindows,
        onKeyEvent: (_) => KeyEventResult.ignored,
        theme: cockpitTerminalThemeFor(Theme.of(context).brightness),
        textStyle: const TerminalStyle(fontSize: 12),
      ),
    );
  }
}
