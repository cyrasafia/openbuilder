import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/domain/models.dart';

void main() {
  test('workspace enablement follows the project commands property', () {
    final disabled = ProjectModel.fromJson({
      'id': 'disabled',
      'worktree': '/repo/disabled',
      'sandboxes': ['/repo/disabled-sandbox'],
    });
    final enabledWithoutScript = ProjectModel.fromJson({
      'id': 'enabled-empty',
      'worktree': '/repo/enabled-empty',
      'commands': {'start': ''},
      'sandboxes': <String>[],
    });
    final enabledWithScript = ProjectModel.fromJson({
      'id': 'enabled-script',
      'worktree': '/repo/enabled-script',
      'commands': {'start': 'setup.sh'},
      'sandboxes': <String>[],
    });

    expect(disabled.workspacesEnabled, isFalse);
    expect(enabledWithoutScript.workspacesEnabled, isTrue);
    expect(enabledWithScript.workspacesEnabled, isTrue);
    expect(enabledWithoutScript.commands?.start, isEmpty);
    expect(enabledWithScript.commands?.start, 'setup.sh');
  });

  test('workspaceCapable reflects vcs availability, independent of commands', () {
    final global = ProjectModel.fromJson({
      'id': 'global',
      'worktree': '/',
    });
    final noVcs = ProjectModel.fromJson({
      'id': 'no-vcs',
      'worktree': '/repo/no-vcs',
    });
    final emptyVcs = ProjectModel.fromJson({
      'id': 'empty-vcs',
      'worktree': '/repo/empty-vcs',
      'vcs': '',
    });
    final git = ProjectModel.fromJson({
      'id': 'git',
      'worktree': '/repo/git',
      'vcs': 'git',
    });
    final gitWithCommands = ProjectModel.fromJson({
      'id': 'git-cmd',
      'worktree': '/repo/git-cmd',
      'vcs': 'git',
      'commands': {'start': 'setup.sh'},
    });

    expect(global.workspaceCapable, isFalse);
    expect(noVcs.workspaceCapable, isFalse);
    expect(emptyVcs.workspaceCapable, isFalse);
    expect(git.workspaceCapable, isTrue);
    expect(gitWithCommands.workspaceCapable, isTrue);
  });
}
