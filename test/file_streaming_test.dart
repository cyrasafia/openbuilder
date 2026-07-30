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

    test('known binary extensions are onDemand', () {
      expect(inferDownloadPolicy('build/app.apk'), DownloadPolicy.onDemand);
      expect(inferDownloadPolicy('archive.zip'), DownloadPolicy.onDemand);
      expect(inferDownloadPolicy('doc.pdf'), DownloadPolicy.onDemand);
      expect(inferDownloadPolicy('setup.exe'), DownloadPolicy.onDemand);
      expect(inferDownloadPolicy('song.mp3'), DownloadPolicy.onDemand);
      expect(inferDownloadPolicy('clip.mp4'), DownloadPolicy.onDemand);
    });

    test('recognized extensionless text basenames are immediate', () {
      expect(inferDownloadPolicy('Makefile'), DownloadPolicy.immediate);
      expect(inferDownloadPolicy('path/to/Dockerfile'), DownloadPolicy.immediate);
      expect(inferDownloadPolicy('LICENSE'), DownloadPolicy.immediate);
      expect(inferDownloadPolicy('Gemfile'), DownloadPolicy.immediate);
      expect(inferDownloadPolicy('dockerfile'), DownloadPolicy.immediate); // case-insensitive
    });

    test('unknown extensionless names fall back to onDemand', () {
      expect(inferDownloadPolicy('run'), DownloadPolicy.onDemand);
      expect(inferDownloadPolicy('bin/app'), DownloadPolicy.onDemand);
      expect(inferDownloadPolicy('someblob'), DownloadPolicy.onDemand);
    });

    test('unknown extension falls back to onDemand', () {
      expect(inferDownloadPolicy('data.xyz'), DownloadPolicy.onDemand);
      expect(inferDownloadPolicy('weird.qqq'), DownloadPolicy.onDemand);
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
