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
