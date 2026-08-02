import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/features/files/markdown_view.dart';

void main() {
  group('MarkdownView._splitFrontMatter (via exposed behavior)', () {
    test('parses a simple front matter block', () {
      final content = '---\n'
          'title: Hello World\n'
          'author: cyra\n'
          '---\n'
          '\n'
          '# Body\n'
          'text';
      final (:frontMatter, :body) = MarkdownView.splitFrontMatter(content);
      expect(frontMatter, isNotNull);
      expect(frontMatter!.length, 2);
      expect(frontMatter[0].key, 'title');
      expect(frontMatter[0].value, 'Hello World');
      expect(frontMatter[1].key, 'author');
      expect(frontMatter[1].value, 'cyra');
      expect(body.startsWith('# Body'), true);
    });

    test('strips one blank line after the closing fence', () {
      final content = '---\ntitle: A\n---\n\nfirst';
      final (:frontMatter, :body) = MarkdownView.splitFrontMatter(content);
      expect(frontMatter, isNotNull);
      expect(body, 'first');
    });

    test('keeps body when no blank line after fence', () {
      final content = '---\ntitle: A\n---\nfirst';
      final (:frontMatter, :body) = MarkdownView.splitFrontMatter(content);
      expect(frontMatter, isNotNull);
      expect(body, 'first');
    });

    test('returns null front matter when content does not start with ---', () {
      final (:frontMatter, :body) = MarkdownView.splitFrontMatter('# Hi');
      expect(frontMatter, isNull);
      expect(body, '# Hi');
    });

    test('returns null when opening fence not at byte 0 (leading space)', () {
      final content = ' ---\ntitle: A\n---\nbody';
      final (:frontMatter, :body) = MarkdownView.splitFrontMatter(content);
      expect(frontMatter, isNull);
      expect(body, content);
    });

    test('returns null when there is no closing fence', () {
      final content = '---\ntitle: A\nbody';
      final (:frontMatter, :body) = MarkdownView.splitFrontMatter(content);
      expect(frontMatter, isNull);
      expect(body, content);
    });

    test('returns null when no key:value lines', () {
      final content = '---\nnot a mapping\n---\nbody';
      final (:frontMatter, :body) = MarkdownView.splitFrontMatter(content);
      expect(frontMatter, isNull);
      expect(body, content);
    });

    test('returns null when a line lacks a colon (mid-block)', () {
      final content = '---\ntitle: A\nbadline\n---\nbody';
      final (:frontMatter, :body) = MarkdownView.splitFrontMatter(content);
      expect(frontMatter, isNull);
      expect(body, content);
    });

    test('unwraps quoted values', () {
      final content = '---\ntitle: "Hello: World"\nnote: \'quoted\'\n---\nbody';
      final (:frontMatter, :body) = MarkdownView.splitFrontMatter(content);
      expect(frontMatter, isNotNull);
      expect(frontMatter![0].value, 'Hello: World');
      expect(frontMatter[1].value, 'quoted');
      expect(body, 'body');
    });

    test('empty value shows em dash placeholder', () {
      final content = '---\ndraft:\n---\nbody';
      final (:frontMatter, :body) = MarkdownView.splitFrontMatter(content);
      expect(frontMatter, isNotNull);
      expect(frontMatter![0].value, '—');
    });

    test('handles empty body after front matter', () {
      final content = '---\ntitle: A\n---\n';
      final (:frontMatter, :body) = MarkdownView.splitFrontMatter(content);
      expect(frontMatter, isNotNull);
      expect(body, '');
    });

    test('too-short content (<4 lines) returns whole as body', () {
      final content = '---\ntitle: A\n---';
      final (:frontMatter, :body) = MarkdownView.splitFrontMatter(content);
      expect(frontMatter, isNull);
      expect(body, content);
    });
  });
}