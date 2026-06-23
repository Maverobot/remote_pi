import 'package:flutter/widgets.dart';

import 'app_colors.dart';
import 'app_typography.dart';
import 'cockpit_theme.dart';
import 'syntax_colors.dart';

/// Acesso ergonômico aos tokens do tema a partir de qualquer widget.
///
/// ```dart
/// Container(color: context.colors.panel);
/// Text('hi', style: context.typo.mono.copyWith(color: context.colors.accent));
/// ```
///
/// Os tokens vêm do [CockpitTheme] (InheritedWidget instalado pela raiz). Se um
/// widget for construído fora dessa árvore (ex.: teste que monta um app cru), os
/// getters caem no dark — o visual padrão — sem lançar.
/// Fallback de tipografia, construído uma vez.
final AppTypography _fallbackTypo = AppTypography.build();

extension AppThemeX on BuildContext {
  AppColors get colors => CockpitTheme.maybeOf(this)?.colors ?? AppColors.dark;

  AppTypography get typo => CockpitTheme.maybeOf(this)?.typo ?? _fallbackTypo;

  SyntaxColors get syntax =>
      CockpitTheme.maybeOf(this)?.syntax ?? SyntaxColors.dark;
}
