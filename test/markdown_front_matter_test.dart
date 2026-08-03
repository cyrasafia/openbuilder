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

    test('skips a colon-less top-level line instead of aborting', () {
      final content = '---\ntitle: A\nbadline\n---\nbody';
      final (:frontMatter, :body) = MarkdownView.splitFrontMatter(content);
      expect(frontMatter, isNotNull);
      expect(frontMatter!.length, 1);
      expect(frontMatter[0].key, 'title');
      expect(frontMatter[0].value, 'A');
      expect(body, 'body');
    });

    test('literal block scalar (|) folds indented continuation lines', () {
      final content = '---\n'
          'title: A\n'
          'description: |\n'
          '  first line\n'
          '  second line\n'
          '---\n'
          'body';
      final (:frontMatter, :body) = MarkdownView.splitFrontMatter(content);
      expect(frontMatter, isNotNull);
      expect(frontMatter!.length, 2);
      expect(frontMatter[1].key, 'description');
      expect(frontMatter[1].value, 'first line\nsecond line');
      expect(body, 'body');
    });

    test('folded block scalar (>) joins lines with spaces', () {
      final content = '---\n'
          'summary: >\n'
          '  one\n'
          '  two\n'
          '---\n'
          'body';
      final (:frontMatter, :body) = MarkdownView.splitFrontMatter(content);
      expect(frontMatter, isNotNull);
      expect(frontMatter![0].key, 'summary');
      expect(frontMatter[0].value, 'one two');
      expect(body, 'body');
    });

    test('nested container keys are stripped and omitted from the card', () {
      final content = '---\n'
          'version: 2\n'
          'name: doc\n'
          'description: |\n'
          '  multi\n'
          '  line\n'
          'colors:\n'
          '  seed-dark: "#4ADE80"\n'
          '  seed-light: "#16A34A"\n'
          '---\n'
          '\n'
          '## Heading';
      final (:frontMatter, :body) = MarkdownView.splitFrontMatter(content);
      expect(frontMatter, isNotNull);
      expect(frontMatter!.length, 3);
      expect(frontMatter.map((e) => e.key).toList(), ['version', 'name', 'description']);
      expect(frontMatter[0].value, '2');
      expect(frontMatter[1].value, 'doc');
      expect(frontMatter[2].value, 'multi\nline');
      expect(body.startsWith('## Heading'), true);
    });

    test('all-container front matter is still stripped from the body', () {
      final content = '---\n'
          'colors:\n'
          '  red: "#f00"\n'
          '  blue: "#00f"\n'
          '---\n'
          '# Body';
      final (:frontMatter, :body) = MarkdownView.splitFrontMatter(content);
      expect(frontMatter, isNull);
      expect(body, '# Body');
    });

    test('horizontal-rule sandwich (no mappings) is not treated as front matter', () {
      final content = '---\n\ntext above\n\n---\ntext below';
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

    test('front matter with empty body is stripped to empty string', () {
      final content = '---\ntitle: A\n---';
      final (:frontMatter, :body) = MarkdownView.splitFrontMatter(content);
      expect(frontMatter, isNotNull);
      expect(frontMatter!.length, 1);
      expect(frontMatter[0].key, 'title');
      expect(body, '');
    });
  });
}