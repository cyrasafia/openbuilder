import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/features/conversation/uri_autolink.dart';

void main() {
  group('autolinkMarkdownUris', () {
    test('no-op when no URI present', () {
      const src = 'just some text, nothing to link here';
      expect(autolinkMarkdownUris(src), src);
    });

    test('http and https in free text become links', () {
      expect(
        autolinkMarkdownUris('see http://a.com and https://b.com/x'),
        'see [http://a.com](http://a.com) and [https://b.com/x](https://b.com/x)',
      );
    });

    test('www gets https destination', () {
      expect(
        autolinkMarkdownUris('visit www.example.com now'),
        'visit [www.example.com](https://www.example.com) now',
      );
    });

    test('ftp scheme is linkified', () {
      expect(
        autolinkMarkdownUris('grab ftp://host/file'),
        'grab [ftp://host/file](ftp://host/file)',
      );
    });

    test('fenced code block URIs are NOT linkified', () {
      const src = '''
before
```dart
const u = 'http://code.example.com';
```
after http://free.example.com''';
      final out = autolinkMarkdownUris(src);
      expect(out, contains('http://code.example.com\';'));
      expect(out, contains('[http://free.example.com](http://free.example.com)'));
      expect(out.contains('[http://code.example.com]'), isFalse);
    });

    test('tilde fenced block is respected', () {
      const src = '~~~\nhttp://tilde.example.com\n~~~';
      expect(autolinkMarkdownUris(src), src);
    });

    test('inline code span that is only a URI IS linkified', () {
      expect(
        autolinkMarkdownUris('see `http://example.com` here'),
        'see [http://example.com](http://example.com) here',
      );
    });

    test('inline www-only code span gets https destination', () {
      expect(
        autolinkMarkdownUris('`www.example.com`'),
        '[www.example.com](https://www.example.com)',
      );
    });

    test('inline code span with extra text is kept as code', () {
      const src = 'run `const u = http://x.com` ok';
      expect(autolinkMarkdownUris(src), src);
    });

    test('existing markdown link is not double-processed', () {
      const src = '[label](http://example.com)';
      expect(autolinkMarkdownUris(src), src);
    });

    test('angle autolink is preserved', () {
      const src = '<http://example.com>';
      expect(autolinkMarkdownUris(src), src);
    });

    test('trailing sentence punctuation is trimmed and preserved', () {
      expect(
        autolinkMarkdownUris('see http://example.com.'),
        'see [http://example.com](http://example.com).',
      );
      expect(
        autolinkMarkdownUris('(http://example.com)!'),
        '([http://example.com](http://example.com))!',
      );
    });

    test('balanced parentheses inside URL are kept', () {
      expect(
        autolinkMarkdownUris('see http://en.wikipedia.org/wiki/Foo_(bar)'),
        'see [http://en.wikipedia.org/wiki/Foo_(bar)](http://en.wikipedia.org/wiki/Foo_(bar))',
      );
    });

    test('www embedded in a word is not matched', () {
      const src = 'mynewww.foo and somewww.example.com';
      expect(autolinkMarkdownUris(src), src);
    });

    test('multiple URIs on one line', () {
      expect(
        autolinkMarkdownUris('a http://a.com b https://b.com'),
        'a [http://a.com](http://a.com) b [https://b.com](https://b.com)',
      );
    });

    test('URI already inside a markdown link destination stays intact', () {
      const src = 'click [here](http://example.com) or visit https://other.com';
      expect(
        autolinkMarkdownUris(src),
        'click [here](http://example.com) or visit [https://other.com](https://other.com)',
      );
    });

    test('unclosed fence protects content to end of input', () {
      const src = 'text http://a.com\n```\nhttp://b.com';
      final out = autolinkMarkdownUris(src);
      expect(out, contains('[http://a.com](http://a.com)'));
      expect(out.contains('[http://b.com]'), isFalse);
    });

    test('CRLF fence still closes and protects content', () {
      const src =
          'before http://a.com\r\n```\r\nhttp://b.com\r\n```\r\nafter http://c.com';
      final out = autolinkMarkdownUris(src);
      expect(out, contains('[http://a.com](http://a.com)'));
      expect(out.contains('[http://b.com]'), isFalse);
      expect(out, contains('[http://c.com](http://c.com)'));
    });

    test('double-backtick code span with only a URI IS linkified', () {
      expect(
        autolinkMarkdownUris('see ``http://example.com`` here'),
        'see [http://example.com](http://example.com) here',
      );
    });

    test('asymmetric backtick span is left verbatim', () {
      const src = 'see ``http://example.com``` end';
      expect(autolinkMarkdownUris(src), src);
    });

    test('empty backtick span does not crash', () {
      expect(
        autolinkMarkdownUris('a `` b http://x.com'),
        'a `` b [http://x.com](http://x.com)',
      );
    });
  });
}
