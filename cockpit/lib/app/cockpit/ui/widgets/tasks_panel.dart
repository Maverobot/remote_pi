import 'package:cockpit/app/cockpit/domain/entities/task_definition.dart';
import 'package:cockpit/app/cockpit/domain/entities/task_run.dart';
import 'package:cockpit/app/cockpit/ui/viewmodels/cockpit_viewmodel.dart';
import 'package:cockpit/app/cockpit/ui/viewmodels/tasks_viewmodel.dart';
import 'package:cockpit/app/core/ui/themes/themes.dart';
import 'package:cockpit/app/core/ui/widgets/app_menu.dart';
import 'package:cockpit/app/core/ui/widgets/hover_tap.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

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
                      key: ValueKey(def.id),
                      def: def,
                      run: vm.stateOf(def.id),
                      watchSupported: vm.watchSupported(def),
                      watchOn: vm.watchOn(def.id),
                      profileName: vm.selectedProfile(def),
                      canCycleProfile: def.profiles.length >= 2,
                      commandPreview: vm.commandPreview(def),
                      adHocArgs: vm.adHocArgs(def.id),
                      // Clicar abre a aba read-only de output no pane central.
                      onTap: () => context
                          .read<CockpitViewModel>()
                          .openTaskOutput(def.id, def.label),
                      onStart: () => vm.start(def),
                      onStop: () => vm.stop(def.id),
                      onRestart: () => vm.restart(def.id),
                      onToggleWatch: () => vm.toggleWatch(def),
                      onCycleProfile: () => vm.cycleProfile(def),
                      onAdHocChanged: (v) => vm.setAdHocArgs(def.id, v),
                      onKey: (k) => vm.sendKey(def.id, k),
                    ),
                ],
              ),
            ),
        ],
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

class _TaskRow extends StatefulWidget {
  const _TaskRow({
    super.key,
    required this.def,
    required this.run,
    required this.watchSupported,
    required this.watchOn,
    required this.profileName,
    required this.canCycleProfile,
    required this.commandPreview,
    required this.adHocArgs,
    required this.onTap,
    required this.onStart,
    required this.onStop,
    required this.onRestart,
    required this.onToggleWatch,
    required this.onCycleProfile,
    required this.onAdHocChanged,
    required this.onKey,
  });

  final TaskDefinition def;
  final TaskRun run;
  final bool watchSupported;
  final bool watchOn;
  final String? profileName;
  final bool canCycleProfile;
  final String commandPreview;
  final String adHocArgs;
  final VoidCallback onTap;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final VoidCallback onRestart;
  final VoidCallback onToggleWatch;
  final VoidCallback onCycleProfile;
  final void Function(String value) onAdHocChanged;
  final void Function(String key) onKey;

  @override
  State<_TaskRow> createState() => _TaskRowState();
}

class _TaskRowState extends State<_TaskRow> {
  late final TextEditingController _args = TextEditingController(
    text: widget.adHocArgs,
  );
  late bool _showArgs = widget.adHocArgs.isNotEmpty;

  @override
  void dispose() {
    _args.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final def = widget.def;
    final active = widget.run.isActive;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _StatusDot(status: widget.run.status),
              const SizedBox(width: 8),
              Expanded(
                // Só abre a aba de output quando a task está viva (tem buffer);
                // parada → não clicável.
                child: HoverTap(
                  onTap: active ? widget.onTap : null,
                  child: Opacity(
                    opacity: active ? 1 : 0.85,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          def.label,
                          style: context.typo.label.copyWith(
                            color: colors.text,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          widget.commandPreview,
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
              ),
              if (active) ...[
                if (widget.watchSupported)
                  _IconAction(
                    tooltip: widget.watchOn
                        ? 'Reload ao salvar: ligado'
                        : 'Reload ao salvar: desligado',
                    icon: widget.watchOn ? Icons.bolt : Icons.bolt_outlined,
                    color: widget.watchOn ? colors.warn : colors.text3,
                    onTap: widget.onToggleWatch,
                  ),
                for (final k in def.interactiveKeys.where((k) => k.primary))
                  _IconAction(
                    tooltip: "${k.label} (envia '${k.key}')",
                    icon: _iconFor(k.icon),
                    fallback: k.key,
                    onTap: () => widget.onKey(k.key),
                  ),
                if (def.interactiveKeys.any((k) => !k.primary))
                  _OverflowKeys(
                    keys: def.interactiveKeys
                        .where((k) => !k.primary)
                        .toList(),
                    onKey: widget.onKey,
                  ),
                _IconAction(
                  tooltip: 'Reiniciar',
                  icon: Icons.restart_alt,
                  onTap: widget.onRestart,
                ),
                _IconAction(
                  tooltip: 'Parar',
                  icon: Icons.stop,
                  color: colors.error,
                  onTap: widget.onStop,
                ),
              ] else ...[
                if (widget.profileName != null)
                  _ProfileChip(
                    name: widget.profileName!,
                    canCycle: widget.canCycleProfile,
                    onTap: widget.onCycleProfile,
                  ),
                _IconAction(
                  tooltip: 'Args extras (uma execução)',
                  icon: Icons.tune,
                  color: _showArgs ? colors.accent : colors.text3,
                  onTap: () => setState(() => _showArgs = !_showArgs),
                ),
                _IconAction(
                  tooltip: 'Rodar',
                  icon: Icons.play_arrow,
                  color: colors.online,
                  onTap: widget.onStart,
                ),
              ],
            ],
          ),
          if (!active && _showArgs)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 2, 0, 2),
              child: TextField(
                controller: _args,
                onChanged: widget.onAdHocChanged,
                placeholder: const Text('+ args (ex.: --dart-define=X=1)'),
                style: context.typo.mono.copyWith(fontSize: 10),
              ),
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

/// Chip que mostra o profile selecionado e cicla pro próximo ao clicar (quando
/// há 2+). Some o `▾` se não dá pra ciclar (profile único).
class _ProfileChip extends StatelessWidget {
  const _ProfileChip({
    required this.name,
    required this.canCycle,
    required this.onTap,
  });

  final String name;
  final bool canCycle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: colors.panel3,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: colors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            name,
            style: context.typo.mono.copyWith(fontSize: 10, color: colors.text2),
          ),
          if (canCycle)
            Icon(Icons.arrow_drop_down, size: 14, color: colors.text3),
        ],
      ),
    );
    if (!canCycle) return Padding(padding: const EdgeInsets.only(right: 2), child: chip);
    return Tooltip(
      tooltip: (context) =>
          const TooltipContainer(child: Text('Trocar profile')),
      child: HoverTap(
        borderRadius: BorderRadius.circular(5),
        onTap: onTap,
        child: chip,
      ),
    );
  }
}

/// Botão `⌨` que reúne as teclas interativas **secundárias** (não-primárias)
/// num menu — evita poluir a linha. Selecionar envia a tecla.
class _OverflowKeys extends StatelessWidget {
  const _OverflowKeys({required this.keys, required this.onKey});

  final List<InteractiveKey> keys;
  final void Function(String key) onKey;

  @override
  Widget build(BuildContext context) {
    return _IconAction(
      tooltip: 'Mais teclas',
      icon: Icons.keyboard,
      onTap: () async {
        final chosen = await showAppMenu<String>(
          context,
          minWidth: 180,
          items: [
            for (final k in keys)
              AppMenuItem(value: k.key, label: '${k.label}  (${k.key})'),
          ],
        );
        if (chosen != null) onKey(chosen);
      },
    );
  }
}
