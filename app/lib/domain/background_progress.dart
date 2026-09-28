/// Ephemeral observations only. Absence is not proof that all work completed.
enum BackgroundTaskState { queued, running, paused, waiting, partial, unknown }

enum BackgroundFreshness { fresh, offline, refreshing, unavailable }

class BackgroundTask {
  final String id;
  final String label;
  final BackgroundTaskState state;
  final Duration? elapsed;
  const BackgroundTask({
    required this.id,
    required this.label,
    required this.state,
    this.elapsed,
  });

  BackgroundTask advance(Duration delta) => BackgroundTask(
    id: id,
    label: label,
    state: state,
    elapsed: elapsed == null || state != BackgroundTaskState.running
        ? elapsed
        : elapsed! + delta,
  );
}

class BackgroundGroup {
  final String id;

  /// Only present when the provider proves workflow membership.
  final String? label;
  final List<BackgroundTask> tasks;
  BackgroundGroup({
    required this.id,
    this.label,
    required List<BackgroundTask> tasks,
  }) : tasks = List.unmodifiable(tasks);
}

class BackgroundProgress {
  final String sessionId;
  final String epoch;
  final bool truncated;
  final BackgroundFreshness freshness;
  final List<BackgroundGroup> groups;
  BackgroundProgress({
    required this.sessionId,
    required this.epoch,
    required this.truncated,
    required this.freshness,
    required List<BackgroundGroup> groups,
  }) : groups = List.unmodifiable(groups);

  int get observedCount =>
      groups.fold(0, (sum, group) => sum + group.tasks.length);
  bool get visible => observedCount > 0 || truncated;
  bool get ticking =>
      freshness == BackgroundFreshness.fresh &&
      groups.any(
        (group) => group.tasks.any(
          (task) =>
              task.state == BackgroundTaskState.running && task.elapsed != null,
        ),
      );

  BackgroundProgress advance(
    Duration delta, {
    BackgroundFreshness? freshness,
  }) => BackgroundProgress(
    sessionId: sessionId,
    epoch: epoch,
    truncated: truncated,
    freshness: freshness ?? this.freshness,
    groups: [
      for (final group in groups)
        BackgroundGroup(
          id: group.id,
          label: group.label,
          tasks: [
            for (final task in group.tasks)
              task.advance(
                this.freshness == BackgroundFreshness.fresh
                    ? delta
                    : Duration.zero,
              ),
          ],
        ),
    ],
  );
}
