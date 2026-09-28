import 'dart:typed_data';
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
    test('text mime yields text + is not binary', () {
      final body = utf8.encode('hello world');
      final f = parseStreamedFile((body, 'text/plain'));
      expect(f.isBinary, isFalse);
      expect(f.text, 'hello world');
      expect(f.bytes, isNull);
    });

    test('binary mime yields raw bytes', () {
      final raw = Uint8List.fromList([1, 2, 3, 250]);
      final f = parseStreamedFile((raw, 'image/png'));
      expect(f.isBinary, isTrue);
      expect(f.mimeType, 'image/png');
      expect(f.bytes, raw);
      expect(f.text, isNull);
    });

    test('null mime defaults to text', () {
      final body = utf8.encode('plain text');
      final f = parseStreamedFile((body, null));
      expect(f.isBinary, isFalse);
      expect(f.text, 'plain text');
    });

    test('json mime is text', () {
      final body = utf8.encode('{"a":1}');
      final f = parseStreamedFile((body, 'application/json'));
      expect(f.isBinary, isFalse);
      expect(f.text, '{"a":1}');
    });
  });
}
