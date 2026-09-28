import 'package:app/domain/background_progress.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';

/// Display-only provider observations. Expansion never changes task execution.
class BackgroundProgressPanel extends StatefulWidget {
  final BackgroundProgress progress;
  const BackgroundProgressPanel({super.key, required this.progress});

  @override
  State<BackgroundProgressPanel> createState() =>
      _BackgroundProgressPanelState();
}

class _BackgroundProgressPanelState extends State<BackgroundProgressPanel> {
  bool _expanded = false;

  String _elapsed(Duration? elapsed) {
    if (elapsed == null) return 'Elapsed unknown';
    final seconds = elapsed.inSeconds;
    if (seconds < 60) return '${seconds}s';
    if (seconds < 3600) return '${seconds ~/ 60}m ${seconds % 60}s';
    return '${seconds ~/ 3600}h ${(seconds % 3600) ~/ 60}m';
  }

  @override
  Widget build(BuildContext context) {
    final progress = widget.progress;
    final stale = switch (progress.freshness) {
      BackgroundFreshness.fresh => null,
      BackgroundFreshness.offline => 'Offline · stale',
      BackgroundFreshness.refreshing => 'Refreshing · stale',
      BackgroundFreshness.unavailable => 'Unavailable · stale',
    };
    final visibleHeight =
        (MediaQuery.sizeOf(context).height -
                MediaQuery.viewInsetsOf(context).bottom -
                MediaQuery.paddingOf(context).vertical)
            .clamp(0.0, double.infinity);
    // Scroll the header as well as rows: stale/truncated labels and large text
    // must fit even when the keyboard leaves little room above the composer.
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: visibleHeight * 0.3),
      child: Material(
        color: context.colors.surface,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                expanded: _expanded,
                child: InkWell(
                  onTap: () => setState(() => _expanded = !_expanded),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Background tasks · ${progress.observedCount} observed',
                                style: context.typo.mono,
                              ),
                              if (stale != null)
                                Text(
                                  stale,
                                  style: context.typo.monoSmall.copyWith(
                                    color: context.colors.warning,
                                  ),
                                ),
                              if (progress.truncated)
                                Text(
                                  'Some task details omitted',
                                  style: context.typo.monoSmall,
                                ),
                            ],
                          ),
                        ),
                        Icon(
                          _expanded ? Icons.expand_less : Icons.expand_more,
                          color: context.colors.muted,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (_expanded)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final group in progress.groups) ...[
                        if (group.label != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              group.label!,
                              style: context.typo.mono.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        for (final task in group.tasks)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(task.label, style: context.typo.sansBody),
                                Text(
                                  '${task.state.name[0].toUpperCase()}${task.state.name.substring(1)} · ${_elapsed(task.elapsed)}',
                                  style: context.typo.monoSmall,
                                ),
                              ],
                            ),
                          ),
                      ],
                      Text(
                        'Observed tasks only. Paused tasks may disappear after Pi restarts.',
                        style: context.typo.monoSmall,
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
