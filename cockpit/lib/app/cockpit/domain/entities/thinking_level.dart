/// Nível de raciocínio (effort) do modelo — comando `set_thinking_level`.
///
/// A escada canônica vai de [off] a [xhigh]. **Quais níveis um modelo aceita** é
/// derivado do `thinkingLevelMap` dele (ver [availableFor]); o que vai no fio é
/// sempre o nome canônico (o pi mapeia pro provider internamente).
enum ThinkingLevel {
  off,
  minimal,
  low,
  medium,
  high,
  xhigh;

  /// String que vai no fio (`{"type":"set_thinking_level","level":"high"}`).
  String get wire => name;

  /// Rótulo (em inglês, como o usuário pediu).
  String get label => switch (this) {
    ThinkingLevel.off => 'off',
    ThinkingLevel.minimal => 'minimal',
    ThinkingLevel.low => 'low',
    ThinkingLevel.medium => 'medium',
    ThinkingLevel.high => 'high',
    ThinkingLevel.xhigh => 'xhigh',
  };

  static ThinkingLevel fromWire(String? value) =>
      ThinkingLevel.values.firstWhere(
        (level) => level.name == value,
        orElse: () => ThinkingLevel.off,
      );

  /// Níveis que **este modelo** aceita, derivados do `thinkingLevelMap`: um
  /// nível fica de fora só quando aparece no mapa com valor `null` (o modelo
  /// declara que não o suporta). Chaves ausentes ficam disponíveis por padrão;
  /// mapa vazio → a escada inteira.
  static List<ThinkingLevel> availableFor(Map<String, String?> map) {
    if (map.isEmpty) return values;
    return [
      for (final level in values)
        if (!(map.containsKey(level.name) && map[level.name] == null)) level,
    ];
  }
}
