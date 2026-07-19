import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/features/projects/worktree_order.dart';

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
}
