import 'package:app/domain/session_state.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

class ThinkingCard extends StatelessWidget {
  final ThinkingMsg message;
  final bool expanded;
  final VoidCallback onToggle;
  const ThinkingCard(
    this.message, {
    super.key,
    required this.expanded,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final observation = message.observation;
    if (!observation.visible) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: context.colors.surface,
        border: Border.all(color: context.colors.border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            button: true,
            expanded: expanded,
            excludeSemantics: true,
            label:
                'Thinking, ${expanded ? "expanded" : "collapsed"}${observation.incomplete ? ", Incomplete" : ""}',
            onTap: onToggle,
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                onTap: onToggle,
                excludeFromSemantics: true,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: Row(
                    children: [
                      Expanded(
                        child: Wrap(
                          spacing: 8,
                          children: [
                            Text('Thinking', style: context.typo.mono),
                            if (observation.incomplete)
                              Text(
                                'Incomplete',
                                style: context.typo.mono.copyWith(
                                  color: context.colors.muted2,
                                ),
                              ),
                          ],
                        ),
                      ),
                      Icon(
                        expanded
                            ? LucideIcons.chevronUp
                            : LucideIcons.chevronDown,
                        size: 16,
                        color: context.colors.muted2,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (expanded)
            SelectableText(
              observation.text,
              style: context.typo.mono.copyWith(color: context.colors.muted2),
            ),
        ],
      ),
    );
  }
}
