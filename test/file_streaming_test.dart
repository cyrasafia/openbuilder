import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/data/api/opencode_client.dart';
import 'package:open_builder/features/files/download_policy.dart';

void main() {
  group('inferDownloadPolicy', () {
    test('image extensions are immediate', () {
      expect(inferDownloadPolicy('a/b.png'), DownloadPolicy.immediate);
      expect(inferDownloadPolicy('photo.JPEG'), DownloadPolicy.immediate);
      expect(inferDownloadPolicy('x.gif'), DownloadPolicy.immediate);
      expect(inferDownloadPolicy('x.webp'), DownloadPolicy.immediate);
    });

    test('text/code extensions are immediate', () {
      expect(inferDownloadPolicy('lib/main.dart'), DownloadPolicy.immediate);
      expect(inferDownloadPolicy('config.json'), DownloadPolicy.immediate);
      expect(inferDownloadPolicy('README.md'), DownloadPolicy.immediate);
      expect(inferDownloadPolicy('logo.svg'), DownloadPolicy.immediate);
      expect(inferDownloadPolicy('notes.txt'), DownloadPolicy.immediate);
      expect(inferDownloadPolicy('app/main.cc'), DownloadPolicy.immediate);
    });

    test('known binary extensions probe the size first', () {
      expect(inferDownloadPolicy('build/app.apk'), DownloadPolicy.probe);
      expect(inferDownloadPolicy('archive.zip'), DownloadPolicy.probe);
      expect(inferDownloadPolicy('doc.pdf'), DownloadPolicy.probe);
      expect(inferDownloadPolicy('setup.exe'), DownloadPolicy.probe);
      expect(inferDownloadPolicy('song.mp3'), DownloadPolicy.probe);
      expect(inferDownloadPolicy('clip.mp4'), DownloadPolicy.probe);
    });

    test('recognized extensionless text basenames are immediate', () {
      expect(inferDownloadPolicy('Makefile'), DownloadPolicy.immediate);
      expect(inferDownloadPolicy('path/to/Dockerfile'), DownloadPolicy.immediate);
      expect(inferDownloadPolicy('LICENSE'), DownloadPolicy.immediate);
      expect(inferDownloadPolicy('Gemfile'), DownloadPolicy.immediate);
      expect(inferDownloadPolicy('dockerfile'), DownloadPolicy.immediate); // case-insensitive
    });

    test('unknown extensionless names probe (e.g. .gitignore is text but unrecognized)', () {
      expect(inferDownloadPolicy('run'), DownloadPolicy.probe);
      expect(inferDownloadPolicy('bin/app'), DownloadPolicy.probe);
      expect(inferDownloadPolicy('someblob'), DownloadPolicy.probe);
      // dotfiles without a real extension (e.g. .gitignore) land here too —
      // lastIndexOf('.') == 0, so they take the extension branch and probe.
      expect(inferDownloadPolicy('.gitignore'), DownloadPolicy.probe);
      expect(inferDownloadPolicy('.envrc'), DownloadPolicy.probe);
    });

    test('unknown extension probes', () {
      expect(inferDownloadPolicy('data.xyz'), DownloadPolicy.probe);
      expect(inferDownloadPolicy('weird.qqq'), DownloadPolicy.probe);
    });

    test('probe threshold is exposed for the UI', () {
      expect(probeThreshold, greaterThan(0));
      expect(probeThreshold, 1024 * 1024);
    });
  });

  group('extensionOf', () {
    test('lowercased ext with dot, or empty', () {
      expect(extensionOf('a/b/c.DART'), '.dart');
      expect(extensionOf('README.md'), '.md');
      expect(extensionOf('Makefile'), '');
      expect(extensionOf('app/Dockerfile'), '');
    });
  });

  group('parseStreamedFile', () {
    test('text content yields text + is not binary', () {
      final body = utf8.encode(jsonEncode({
        'type': 'text',
        'content': 'hello world',
      }));
      final f = parseStreamedFile(body);
      expect(f.isBinary, isFalse);
      expect(f.text, 'hello world');
      expect(f.bytes, isNull);
    });

    test('binary base64 content decodes to bytes', () {
      final raw = [1, 2, 3, 250];
      final body = utf8.encode(jsonEncode({
        'type': 'binary',
        'content': base64Encode(raw),
        'encoding': 'base64',
        'mimeType': 'image/png',
      }));
      final f = parseStreamedFile(body);
      expect(f.isBinary, isTrue);
      expect(f.mimeType, 'image/png');
      expect(f.bytes, raw);
      expect(f.text, isNull);
    });

    test('binary without base64 falls to text branch (bytes null)', () {
      final body = utf8.encode(jsonEncode({
        'type': 'binary',
        'content': '',
        'encoding': '',
      }));
      final f = parseStreamedFile(body);
      expect(f.isBinary, isTrue);
      expect(f.bytes, isNull);
    });

    test('defaults type to text when absent', () {
      final body = utf8.encode(jsonEncode({'content': 'x'}));
      final f = parseStreamedFile(body);
      expect(f.isBinary, isFalse);
      expect(f.text, 'x');
    });
  });
}
