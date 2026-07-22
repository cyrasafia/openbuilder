import '../../domain/models.dart';

int compareWorktreePaths(
  String a,
  String b, {
  required String mainWorktree,
  required Map<String, int> sandboxOrder,
}) {
  if (a == b) return 0;
  if (a == mainWorktree) return -1;
  if (b == mainWorktree) return 1;
  final ai = sandboxOrder[a];
  final bi = sandboxOrder[b];
  if (ai != null && bi != null) return ai.compareTo(bi);
  if (ai != null) return -1;
  if (bi != null) return 1;
  return a.compareTo(b);
}

/// Groups [sessions] by worktree (directory) and orders the groups the way the
/// project detail screen renders them: main worktree first, then sandboxes in
/// creation order, then any unknown directories alphabetically. Within a group,
/// sessions keep most-recently-updated-first order.
///
/// This is the single source of truth for session ordering shared by the
/// project detail screen (sectioned list) and the project list tab (status
/// glyph row), so the two always agree.
List<({String directory, List<SessionModel> sessions})> groupSessionsByWorktree(
  Iterable<SessionModel> sessions, {
  required String mainWorktree,
  required Map<String, int> sandboxOrder,
}) {
  final list = sessions.toList()
    ..sort((a, b) => b.updated.compareTo(a.updated));
  final byDir = <String, List<SessionModel>>{};
  for (final s in list) {
    byDir.putIfAbsent(s.directory, () => []).add(s);
  }
  final groups = byDir.entries.toList()
    ..sort(
      (a, b) => compareWorktreePaths(
        a.key,
        b.key,
        mainWorktree: mainWorktree,
        sandboxOrder: sandboxOrder,
      ),
    );
  return [
    for (final e in groups) (directory: e.key, sessions: e.value),
  ];
}
