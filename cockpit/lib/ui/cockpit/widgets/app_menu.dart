import 'package:cockpit/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';

/// Um item de [showAppMenu]: ícone (opcional) à esquerda + rótulo, com check à
/// direita quando [selected] e cor de erro quando [danger] (ação destrutiva).
class AppMenuItem<T> {
  const AppMenuItem({
    required this.value,
    required this.label,
    this.icon,
    this.selected = false,
    this.danger = false,
  });

  final T value;
  final String label;
  final IconData? icon;
  final bool selected;
  final bool danger;
}

/// Menu popup **compacto**. Por padrão ancora no widget que chamou (via
/// [context]): abre logo **abaixo** do trigger — ideal pra botões. Passando
/// [globalPosition] (ex.: `onSecondaryTapUp(d).globalPosition`), abre no **ponto
/// do clique** — ideal pra menu de contexto (botão direito). Sobe/recua sozinho
/// se não couber. Ícone à esquerda, check à direita do selecionado. Devolve o
/// `value` escolhido (ou `null`).
///
/// Componente único do app — todos os menus passam por aqui.
Future<T?> showAppMenu<T>(
  BuildContext context, {
  required List<AppMenuItem<T>> items,
  double minWidth = 200,
  Offset? globalPosition,
}) {
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
  if (overlay == null) return Future<T?>.value();

  final colors = context.colors;
  final RelativeRect position;
  if (globalPosition != null) {
    // Menu de contexto: âncora no cursor (abre logo abaixo-direita do clique).
    final local = overlay.globalToLocal(globalPosition);
    position = RelativeRect.fromLTRB(
      local.dx,
      local.dy,
      overlay.size.width - local.dx,
      0,
    );
  } else {
    final trigger = context.findRenderObject() as RenderBox?;
    if (trigger == null) return Future<T?>.value();
    final topLeft = trigger.localToGlobal(Offset.zero, ancestor: overlay);
    final bottomLeft = trigger.localToGlobal(
      trigger.size.bottomLeft(Offset.zero),
      ancestor: overlay,
    );
    // Âncora na borda inferior-esquerda do trigger; o showMenu sobe sozinho se
    // não couber abaixo (ex.: composer no rodapé).
    position = RelativeRect.fromLTRB(
      topLeft.dx,
      bottomLeft.dy + 4,
      overlay.size.width - topLeft.dx,
      0,
    );
  }

  return showMenu<T>(
    context: context,
    position: position,
    color: colors.panel2,
    surfaceTintColor: Colors.transparent,
    elevation: 8,
    shadowColor: const Color(0x66000000),
    constraints: BoxConstraints(minWidth: minWidth, maxWidth: 320),
    menuPadding: const EdgeInsets.symmetric(vertical: 4),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(10),
      side: BorderSide(color: colors.border2),
    ),
    items: [
      for (final item in items)
        PopupMenuItem<T>(
          value: item.value,
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: _AppMenuRow(
            icon: item.icon,
            label: item.label,
            selected: item.selected,
            danger: item.danger,
          ),
        ),
    ],
  );
}

class _AppMenuRow extends StatelessWidget {
  const _AppMenuRow({
    required this.icon,
    required this.label,
    required this.selected,
    required this.danger,
  });

  final IconData? icon;
  final String label;
  final bool selected;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final fg = danger ? colors.error : colors.text;
    final iconColor = danger ? colors.error : colors.text3;
    return Row(
      children: [
        if (icon != null) ...[
          Icon(icon, size: 15, color: iconColor),
          const SizedBox(width: 11),
        ],
        Expanded(
          child: Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: context.typo.body.copyWith(fontSize: 13, color: fg),
          ),
        ),
        if (selected) ...[
          const SizedBox(width: 12),
          Icon(Icons.check, size: 14, color: colors.accentText),
        ],
      ],
    );
  }
}
