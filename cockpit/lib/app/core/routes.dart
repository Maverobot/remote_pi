/// Constantes de path de navegação. Cada feature declara sua rota no seu próprio
/// módulo (`createModule(path: …)`); estes consts só evitam strings mágicas nos
/// call-sites de navegação (`context.pushNamed(RoutePaths.settings)`).
abstract final class RoutePaths {
  static const String shell = '/';
  static const String settings = '/settings';
}
