import 'dart:io';

import 'package:cockpit/app/cockpit/domain/entities/launchable_app.dart';
import 'package:cockpit/app/core/ui/menu/app_menu_bar.dart';
import 'package:cockpit/app/core/ui/settings_controller.dart';
import 'package:cockpit/app/core/ui/widgets/app_menu.dart';
import 'package:cockpit/app/core/ui/widgets/window_controls.dart';
import 'package:cockpit/app/core/ui/themes/themes.dart';
import 'package:cockpit/app/core/ui/widgets/hover_tap.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

/// Top bar (~46px) customizada — substitui a barra nativa da janela. Semáforo
/// macOS **funcional** (fecha/minimiza/maximiza) · toggle da rail · nome do
/// projeto · botão "Abrir" (split: IDE | dropdown). A barra inteira arrasta a
/// janela (via [WindowTitleBar]).
class CockpitTopbar extends StatelessWidget {
  const CockpitTopbar({
    super.key,
    required this.projectName,
    required this.railVisible,
    required this.treeVisible,
    required this.onToggleRail,
    required this.onToggleTree,
    required this.availableApps,
    required this.onOpenInApp,
    this.lastOpenAppId,
    this.openEnabled = true,
  });

  final String projectName;
  final bool railVisible;
  final bool treeVisible;
  final VoidCallback onToggleRail;
  final VoidCallback onToggleTree;

  /// Apps disponíveis para abrir o workspace (vazio = botão desabilitado).
  final List<LaunchableApp> availableApps;

  /// Último app usado (pode não estar mais em [availableApps]).
  final String? lastOpenAppId;

  /// Chamado com o `id` do app escolhido (click no segmento esquerdo ou no menu).
  final void Function(String appId) onOpenInApp;

  /// Botão desabilitado quando não há workspace selecionado.
  final bool openEnabled;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return WindowTitleBar(
      children: [
        const WindowControls(),
        const SizedBox(width: 12),
        // Windows/Linux: barra de menu desenhada na janela (estilo VS Code), ao
        // lado do título. No macOS o [WindowMenuBar] é no-op (barra é a nativa).
        if (!Platform.isMacOS) ...[
          WindowMenuBar(menus: buildAppMenus(context.watch<SettingsController>())),
          const SizedBox(width: 8),
        ],
        _IconBtn(
          icon: Icons.view_sidebar_outlined,
          tooltip: 'Collapse sidebar',
          active: !railVisible,
          onTap: onToggleRail,
        ),
        const SizedBox(width: 8),
        Text(
          projectName,
          style: context.typo.title.copyWith(fontSize: 14, color: colors.text),
        ),
        const Spacer(),
        _OpenInIdeButton(
          apps: availableApps,
          lastAppId: lastOpenAppId,
          enabled: openEnabled && availableApps.isNotEmpty,
          onOpen: (id) => onOpenInApp(id),
        ),
        const SizedBox(width: 8),
        _IconBtn(
          icon: Icons.view_sidebar_outlined,
          tooltip: 'Show/hide files',
          active: !treeVisible,
          onTap: onToggleTree,
        ),
        const WindowControlsTrailing(),
      ],
    );
  }
}

// --------------------------------------------------------------------------

/// Botão split: segmento esquerdo [ícone + "Abrir"] abre no último app; segmento
/// direito [chevron] mostra dropdown com todos os apps disponíveis + checkmark.
class _OpenInIdeButton extends StatelessWidget {
  const _OpenInIdeButton({
    required this.apps,
    required this.lastAppId,
    required this.onOpen,
    this.enabled = true,
  });

  final List<LaunchableApp> apps;
  final String? lastAppId;
  final void Function(String id) onOpen;
  final bool enabled;

  LaunchableApp? get _current {
    if (apps.isEmpty) return null;
    if (lastAppId != null) {
      for (final a in apps) {
        if (a.id == lastAppId) return a;
      }
    }
    return apps.first;
  }

  void _showApps(BuildContext context, LaunchableApp? current) {
    final colors = context.colors;
    final overlay = showPopover<void>(
      context: context,
      alignment: Alignment.topRight,
      anchorAlignment: Alignment.bottomRight,
      offset: const Offset(0, 4),
      builder: (context) => ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 180, maxWidth: 320),
        // DropdownMenu embrulha os MenuButton num MenuGroup (exigido) + MenuPopup.
        child: DropdownMenu(
          children: [
            for (final app in apps)
              MenuButton(
                leading: _AppIcon(app, size: 14, color: colors.text2),
                trailing: app.id == current?.id
                    ? Icon(Icons.check, size: 14, color: colors.accent)
                    : null,
                onPressed: (ctx) {
                  closeOverlay(ctx);
                  onOpen(app.id);
                },
                child: Text(
                  app.name,
                  style: context.typo.label.copyWith(
                    color: colors.text,
                    fontSize: 13,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
    trackMenuOverlay(overlay);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final current = _current;
    final fg = enabled ? Colors.white : colors.text4;
    final bg = enabled ? colors.accent : colors.panel3;
    final hover = Colors.white.withValues(alpha: 0.12);

    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(7),
      ),
      clipBehavior: Clip.hardEdge,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Segmento esquerdo — abre no app atual
          HoverTap(
            onTap: enabled && current != null ? () => onOpen(current.id) : null,
            hoverColor: hover,
            borderRadius: BorderRadius.zero,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _AppIcon(current, size: 14, color: fg),
                const SizedBox(width: 7),
                Text(
                  'Open',
                  style: context.typo.label.copyWith(
                    color: fg,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          // Divisor vertical
          Container(width: 1, height: 28, color: fg.withValues(alpha: 0.25)),
          // Segmento direito — dropdown de apps
          Builder(
            builder: (ctx) => HoverTap(
              onTap: enabled && apps.isNotEmpty
                  ? () => _showApps(ctx, current)
                  : null,
              hoverColor: hover,
              borderRadius: BorderRadius.zero,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
              child: Icon(Icons.expand_more, size: 16, color: fg),
            ),
          ),
        ],
      ),
    );
  }
}

/// Mostra o ícone do app extraído do bundle (PNG) ou cai num ícone Material.
class _AppIcon extends StatelessWidget {
  const _AppIcon(this.app, {this.size = 14, this.color});

  final LaunchableApp? app;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final path = app?.iconPath;
    if (path != null) {
      return Image.file(
        File(path),
        width: size,
        height: size,
        filterQuality: FilterQuality.medium,
      );
    }
    return Icon(_iconFor(app?.id), size: size, color: color);
  }
}

IconData _iconFor(String? id) {
  return switch (id) {
    'cursor' => Icons.auto_awesome,
    'windsurf' => Icons.waves,
    'antigravity' => Icons.rocket_launch,
    'vscode' => Icons.code,
    'finder' => Icons.folder_open,
    _ => Icons.open_in_new,
  };
}

// --------------------------------------------------------------------------

class _IconBtn extends StatelessWidget {
  const _IconBtn({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.active = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Tooltip(
      tooltip: (context) => TooltipContainer(child: Text(tooltip)),
      child: HoverTap(
        onTap: onTap,
        color: active ? colors.accentSoft : null,
        hoverColor: colors.panel3,
        borderRadius: BorderRadius.circular(5),
        child: SizedBox(
          width: 28,
          height: 28,
          child: Icon(
            icon,
            size: 17,
            color: active ? colors.accentText : colors.text3,
          ),
        ),
      ),
    );
  }
}
