import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/domain/models.dart';

void main() {
  group('Permission.fromJson', () {
    test('v1 external_directory with metadata → shows parentDir', () {
      final p = Permission.fromJson({
        'id': 'per_1',
        'sessionID': 'ses_1',
        'permission': 'external_directory',
        'patterns': ['/tmp/outside/*'],
        'metadata': {
          'filepath': '/tmp/outside/secret.txt',
          'parentDir': '/tmp/outside',
        },
        'always': ['/tmp/outside/*'],
      });
      expect(p.type, 'external_directory');
      expect(p.title, '访问目录 /tmp/outside');
      expect(p.patterns, ['/tmp/outside/*']);
      expect(p.metadata?['parentDir'], '/tmp/outside');
    });

    test('v1 external_directory metadata missing filepath but has parentDir', () {
      final p = Permission.fromJson({
        'id': 'per_2',
        'sessionID': 'ses_1',
        'permission': 'external_directory',
        'patterns': ['/tmp/outside/*'],
        'metadata': {'parentDir': '/tmp/outside'},
        'always': [],
      });
      expect(p.title, '访问目录 /tmp/outside');
    });

    test('v1 external_directory without metadata → derives dir from glob', () {
      final p = Permission.fromJson({
        'id': 'per_3',
        'sessionID': 'ses_1',
        'permission': 'external_directory',
        'patterns': ['/home/me/elsewhere/*'],
        'metadata': <String, dynamic>{},
        'always': [],
      });
      expect(p.title, '访问目录 /home/me/elsewhere');
    });

    test('external_directory with nothing usable → generic fallback', () {
      final p = Permission.fromJson({
        'id': 'per_4',
        'sessionID': 'ses_1',
        'permission': 'external_directory',
        'patterns': <String>[],
      });
      expect(p.title, '外部目录访问');
    });

    test('v2 external_directory (action/resources) → type + dir shown', () {
      final p = Permission.fromJson({
        'id': 'per_5',
        'sessionID': 'ses_1',
        'action': 'external_directory',
        'resources': ['/tmp/outside/*'],
        'metadata': {
          'filepath': '/tmp/outside/secret.txt',
          'parentDir': '/tmp/outside',
        },
      });
      expect(p.type, 'external_directory');
      expect(p.title, '访问目录 /tmp/outside');
      expect(p.patterns, ['/tmp/outside/*']);
    });

    test('v2 external_directory no metadata → derives from resources', () {
      final p = Permission.fromJson({
        'id': 'per_6',
        'sessionID': 'ses_1',
        'action': 'external_directory',
        'resources': ['/data/elsewhere/*'],
      });
      expect(p.type, 'external_directory');
      expect(p.title, '访问目录 /data/elsewhere');
    });

    test('bash permission → 执行命令', () {
      final p = Permission.fromJson({
        'id': 'per_7',
        'sessionID': 'ses_1',
        'permission': 'bash',
        'patterns': ['rm -rf /'],
        'metadata': <String, dynamic>{},
        'always': [],
      });
      expect(p.title, '执行命令');
    });

    test('unknown permission type → echoes type string', () {
      final p = Permission.fromJson({
        'id': 'per_8',
        'sessionID': 'ses_1',
        'permission': 'webfetch',
        'patterns': [],
        'metadata': <String, dynamic>{},
        'always': [],
      });
      expect(p.title, 'webfetch');
    });

    test('empty payload → generic 权限请求', () {
      final p = Permission.fromJson({'id': 'per_9', 'sessionID': 'ses_1'});
      expect(p.type, '');
      expect(p.title, '权限请求');
      expect(p.patterns, isEmpty);
    });

    test('parentDir empty string is ignored, filepath used instead', () {
      final p = Permission.fromJson({
        'id': 'per_10',
        'sessionID': 'ses_1',
        'permission': 'external_directory',
        'patterns': ['/tmp/outside/*'],
        'metadata': {'parentDir': '', 'filepath': '/tmp/outside/file.txt'},
        'always': [],
      });
      expect(p.title, '访问目录 /tmp/outside/file.txt');
    });

    test('type-only carrier (permission/action absent) → recognized', () {
      final p = Permission.fromJson({
        'id': 'per_11',
        'sessionID': 'ses_1',
        'type': 'external_directory',
        'patterns': ['/tmp/outside/*'],
        'metadata': {'parentDir': '/tmp/outside'},
      });
      expect(p.type, 'external_directory');
      expect(p.title, '访问目录 /tmp/outside');
    });
  });
}
