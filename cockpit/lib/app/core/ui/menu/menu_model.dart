import 'dart:io' show Platform;

import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:shadcn_flutter/shadcn_flutter.dart' show SingleActivator;

/// Modelo declarativo de barra de menu, **agnóstico de plataforma**. Uma única
/// árvore de [MenuNode] é a fonte de verdade; os renderers a traduzem pro alvo:
///
/// - **macOS** → `PlatformMenuBar` (barra nativa do SO, no topo da tela);
/// - **Windows/Linux** → `Menubar` do design system, desenhado dentro da janela
///   (não existe barra de menu do SO alcançável pelo Flutter nessas plataformas —
///   ver `app_menu_bar.dart`).
///
/// Ver [buildAppMenus] (definição única do menu do app) e [menuShortcuts]
/// (atalhos derivados do próprio modelo, sem redeclarar teclas).
sealed class MenuNode {
  const MenuNode();
}

/// Acelerador de teclado com **modificador primário** resolvido por plataforma:
/// ⌘ no macOS, Ctrl no Windows/Linux — a convenção esperada em cada SO. Guardar
/// o modificador de forma abstrata evita declarar a tecla duas vezes (uma pro
/// menu nativo, outra pro handler) e mantém o hint visual correto em cada SO.
class MenuAccelerator {
  const MenuAccelerator(this.key, {this.shift = false});

  final LogicalKeyboardKey key;
  final bool shift;

  SingleActivator resolve() => SingleActivator(
    key,
    meta: Platform.isMacOS,
    control: !Platform.isMacOS,
    shift: shift,
  );
}

/// Menu de topo ou submenu: um rótulo que abre uma lista de [items].
class MenuBarMenu extends MenuNode {
  const MenuBarMenu(this.label, this.items);

  final String label;
  final List<MenuNode> items;
}

/// Item acionável (folha). [onSelected] `null` = desabilitado (cinza, sem clique).
class MenuAction extends MenuNode {
  const MenuAction(this.label, {this.accelerator, this.onSelected});

  final String label;
  final MenuAccelerator? accelerator;
  final void Function()? onSelected;
}

/// Divisória entre grupos de itens (linha no menu).
class MenuSeparator extends MenuNode {
  const MenuSeparator();
}

/// Item padrão provido pelo SO. No macOS vira `PlatformProvidedMenuItem` (real);
/// no Windows/Linux os que têm equivalente ([MenuBarRole.quit],
/// [MenuBarRole.minimizeWindow], [MenuBarRole.zoomWindow]) são implementados à
/// mão via `window_manager`, e os exclusivos do macOS (about/services/hide/…)
/// são simplesmente omitidos.
class MenuRole extends MenuNode {
  const MenuRole(this.role);

  final MenuBarRole role;
}

enum MenuBarRole {
  about,
  services,
  hide,
  hideOthers,
  showAll,
  quit,
  minimizeWindow,
  zoomWindow,
}

/// Coleta os atalhos declarados no próprio modelo → `Map` pronto pro
/// `CallbackShortcuts`. Usado **só fora do macOS**: lá a barra nativa já dispara
/// os aceleradores; duplicar no `CallbackShortcuts` faria a ação rodar duas
/// vezes. Recursivo (cobre submenus).
Map<SingleActivator, void Function()> menuShortcuts(List<MenuNode> nodes) {
  final out = <SingleActivator, void Function()>{};
  void walk(List<MenuNode> items) {
    for (final node in items) {
      switch (node) {
        case MenuBarMenu():
          walk(node.items);
        case MenuAction(:final accelerator?, :final onSelected?):
          out[accelerator.resolve()] = onSelected;
        case MenuAction():
        case MenuSeparator():
        case MenuRole():
          break;
      }
    }
  }

  walk(nodes);
  return out;
}
