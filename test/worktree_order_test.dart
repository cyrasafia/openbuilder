import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/domain/models.dart';
import 'package:open_builder/features/projects/worktree_order.dart';

SessionModel _session(String id, String dir, int updated) => SessionModel(
      id: id,
      projectID: 'p',
      directory: dir,
      title: id,
      created: 0,
      updated: updated,
    );

void main() {
  test('main worktree is first and sandboxes follow creation order', () {
    final paths = ['/repo/later', '/repo', '/repo/earlier'];
    final order = {'/repo/earlier': 0, '/repo/later': 1};

    paths.sort(
      (a, b) => compareWorktreePaths(
        a,
        b,
        mainWorktree: '/repo',
        sandboxOrder: order,
      ),
    );

    expect(paths, ['/repo', '/repo/earlier', '/repo/later']);
  });

  test('comparison is symmetric and unknown worktrees sort last', () {
    final order = {'/repo/known': 0};

    expect(
      compareWorktreePaths(
        '/repo',
        '/repo',
        mainWorktree: '/repo',
        sandboxOrder: order,
      ),
      0,
    );
    expect(
      compareWorktreePaths(
        '/repo/known',
        '/repo/unknown',
        mainWorktree: '/repo',
        sandboxOrder: order,
      ),
      lessThan(0),
    );
    expect(
      compareWorktreePaths(
        '/repo/unknown',
        '/repo/known',
        mainWorktree: '/repo',
        sandboxOrder: order,
      ),
      greaterThan(0),
    );
  });

  group('groupSessionsByWorktree', () {
    test('main worktree group precedes sandboxes even when older', () {
      final groups = groupSessionsByWorktree(
        [
          _session('sb', '/repo/sandbox', 90),
          _session('main', '/repo', 10),
        ],
        mainWorktree: '/repo',
        sandboxOrder: {'/repo/sandbox': 0},
      );
      expect(groups.map((g) => g.directory), ['/repo', '/repo/sandbox']);
    });

    test('recency order is preserved within a group', () {
      final groups = groupSessionsByWorktree(
        [
          _session('old', '/repo', 10),
          _session('new', '/repo', 99),
          _session('mid', '/repo', 50),
        ],
        mainWorktree: '/repo',
        sandboxOrder: const {},
      );
      expect(groups.single.directory, '/repo');
      expect(groups.single.sessions.map((s) => s.id), ['new', 'mid', 'old']);
    });

    test('sandboxes follow creation order, not alphabetical', () {
      final groups = groupSessionsByWorktree(
        [
          _session('z', '/repo/zeta', 1),
          _session('a', '/repo/alpha', 2),
        ],
        mainWorktree: '/repo',
        sandboxOrder: {'/repo/zeta': 0, '/repo/alpha': 1},
      );
      expect(groups.map((g) => g.directory), ['/repo/zeta', '/repo/alpha']);
    });

    test('empty input yields no groups', () {
      expect(
        groupSessionsByWorktree(
          const [],
          mainWorktree: '/repo',
          sandboxOrder: const {},
        ),
        isEmpty,
      );
    });

    test('flat ordering matches a flatten across groups', () {
      // Reproduces the project-list glyph ordering: a newer sandbox session
      // must NOT outrank an older main-worktree session.
      final groups = groupSessionsByWorktree(
        [
          _session('sbNew', '/repo/sandbox', 999),
          _session('mainOld', '/repo', 1),
          _session('mainMid', '/repo', 5),
        ],
        mainWorktree: '/repo',
        sandboxOrder: {'/repo/sandbox': 0},
      );
      final flat = [for (final g in groups) for (final s in g.sessions) s.id];
      expect(flat, ['mainMid', 'mainOld', 'sbNew']);
    });
  });
}
