import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/features/conversation/message_autolink.dart';

void main() {
  group('autolinkMarkdownLinks', () {
    test('no-op when no URI present', () {
      const src = 'just some text, nothing to link here';
      expect(autolinkMarkdownLinks(src), src);
    });

    test('http and https in free text become links', () {
      expect(
        autolinkMarkdownLinks('see http://a.com and https://b.com/x'),
        'see [http://a.com](http://a.com) and [https://b.com/x](https://b.com/x)',
      );
    });

    test('www gets https destination', () {
      expect(
        autolinkMarkdownLinks('visit www.example.com now'),
        'visit [www.example.com](https://www.example.com) now',
      );
    });

    test('ftp scheme is linkified', () {
      expect(
        autolinkMarkdownLinks('grab ftp://host/file'),
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
      final out = autolinkMarkdownLinks(src);
      expect(out, contains('http://code.example.com\';'));
      expect(out, contains('[http://free.example.com](http://free.example.com)'));
      expect(out.contains('[http://code.example.com]'), isFalse);
    });

    test('tilde fenced block is respected', () {
      const src = '~~~\nhttp://tilde.example.com\n~~~';
      expect(autolinkMarkdownLinks(src), src);
    });

    test('inline code span that is only a URI IS linkified', () {
      expect(
        autolinkMarkdownLinks('see `http://example.com` here'),
        'see [http://example.com](http://example.com) here',
      );
    });

    test('inline www-only code span gets https destination', () {
      expect(
        autolinkMarkdownLinks('`www.example.com`'),
        '[www.example.com](https://www.example.com)',
      );
    });

    test('inline code span with extra text is kept as code', () {
      const src = 'run `const u = http://x.com` ok';
      expect(autolinkMarkdownLinks(src), src);
    });

    test('existing markdown link is not double-processed', () {
      const src = '[label](http://example.com)';
      expect(autolinkMarkdownLinks(src), src);
    });

    test('angle autolink is preserved', () {
      const src = '<http://example.com>';
      expect(autolinkMarkdownLinks(src), src);
    });

    test('trailing sentence punctuation is trimmed and preserved', () {
      expect(
        autolinkMarkdownLinks('see http://example.com.'),
        'see [http://example.com](http://example.com).',
      );
      expect(
        autolinkMarkdownLinks('(http://example.com)!'),
        '([http://example.com](http://example.com))!',
      );
    });

    test('balanced parentheses inside URL are kept', () {
      expect(
        autolinkMarkdownLinks('see http://en.wikipedia.org/wiki/Foo_(bar)'),
        'see [http://en.wikipedia.org/wiki/Foo_(bar)](http://en.wikipedia.org/wiki/Foo_(bar))',
      );
    });

    test('www embedded in a word is not matched', () {
      const src = 'mynewww.foo and somewww.example.com';
      expect(autolinkMarkdownLinks(src), src);
    });

    test('multiple URIs on one line', () {
      expect(
        autolinkMarkdownLinks('a http://a.com b https://b.com'),
        'a [http://a.com](http://a.com) b [https://b.com](https://b.com)',
      );
    });

    test('URI already inside a markdown link destination stays intact', () {
      const src = 'click [here](http://example.com) or visit https://other.com';
      expect(
        autolinkMarkdownLinks(src),
        'click [here](http://example.com) or visit [https://other.com](https://other.com)',
      );
    });

    test('unclosed fence protects content to end of input', () {
      const src = 'text http://a.com\n```\nhttp://b.com';
      final out = autolinkMarkdownLinks(src);
      expect(out, contains('[http://a.com](http://a.com)'));
      expect(out.contains('[http://b.com]'), isFalse);
    });

    test('CRLF fence still closes and protects content', () {
      const src =
          'before http://a.com\r\n```\r\nhttp://b.com\r\n```\r\nafter http://c.com';
      final out = autolinkMarkdownLinks(src);
      expect(out, contains('[http://a.com](http://a.com)'));
      expect(out.contains('[http://b.com]'), isFalse);
      expect(out, contains('[http://c.com](http://c.com)'));
    });

    test('double-backtick code span with only a URI IS linkified', () {
      expect(
        autolinkMarkdownLinks('see ``http://example.com`` here'),
        'see [http://example.com](http://example.com) here',
      );
    });

    test('asymmetric backtick span is left verbatim', () {
      const src = 'see ``http://example.com``` end';
      expect(autolinkMarkdownLinks(src), src);
    });

    test('empty backtick span does not crash', () {
      expect(
        autolinkMarkdownLinks('a `` b http://x.com'),
        'a `` b [http://x.com](http://x.com)',
      );
    });
  });

  group('file paths', () {
    test('relative path becomes an ob-file link', () {
      expect(
        autolinkMarkdownLinks('see lib/foo.dart for details'),
        'see [lib/foo.dart](ob-file:///lib/foo.dart) for details',
      );
    });

    test('dot-prefixed relative paths', () {
      expect(
        autolinkMarkdownLinks('open ./src/a.ts and ../x/y.md'),
        'open [./src/a.ts](ob-file:///./src/a.ts) and '
        '[../x/y.md](ob-file:///../x/y.md)',
      );
    });

    test('absolute path becomes an ob-file link', () {
      expect(
        autolinkMarkdownLinks('edit /home/u/proj/lib/foo.dart now'),
        'edit [/home/u/proj/lib/foo.dart](ob-file:////home/u/proj/lib/foo.dart) now',
      );
    });

    test('root-level absolute path is not recognized', () {
      const src = 'see /foo.dart here';
      expect(autolinkMarkdownLinks(src), src);
    });

    test('dotfile final segment is recognized', () {
      expect(
        autolinkMarkdownLinks('check config/.gitignore please'),
        'check [config/.gitignore](ob-file:///config/.gitignore) please',
      );
    });

    test('line suffix is extracted into the query', () {
      expect(
        autolinkMarkdownLinks('at lib/foo.dart:42 now'),
        'at [lib/foo.dart:42](ob-file:///lib/foo.dart?line=42) now',
      );
      expect(
        autolinkMarkdownLinks('at lib/foo.dart:42:10 now'),
        'at [lib/foo.dart:42:10](ob-file:///lib/foo.dart?line=42) now',
      );
    });

    test('trailing punctuation stays outside the link', () {
      expect(
        autolinkMarkdownLinks('see lib/foo.dart, then'),
        'see [lib/foo.dart](ob-file:///lib/foo.dart), then',
      );
      expect(
        autolinkMarkdownLinks('see lib/foo.dart:123, then'),
        'see [lib/foo.dart:123](ob-file:///lib/foo.dart?line=123), then',
      );
      expect(
        autolinkMarkdownLinks('(lib/foo.dart)'),
        '([lib/foo.dart](ob-file:///lib/foo.dart))',
      );
    });

    test('URI wins over path segments', () {
      expect(
        autolinkMarkdownLinks('open http://example.com/a/b.dart now'),
        'open [http://example.com/a/b.dart](http://example.com/a/b.dart) now',
      );
      expect(
        autolinkMarkdownLinks('open www.example.com/x/y.dart now'),
        'open [www.example.com/x/y.dart](https://www.example.com/x/y.dart) now',
      );
    });

    test('bare domain URL is not treated as a file path', () {
      const src = 'see github.com/org/repo/blob/main/foo.dart';
      expect(autolinkMarkdownLinks(src), src);
    });

    test('dot-leading directory is not a bare domain', () {
      expect(
        autolinkMarkdownLinks('ci in .github/workflows/ci.yml now'),
        'ci in [.github/workflows/ci.yml](ob-file:///.github/workflows/ci.yml) now',
      );
    });

    test('single-segment filename is not recognized', () {
      const src = 'edit main.dart now';
      expect(autolinkMarkdownLinks(src), src);
    });

    test('extension-less final segment is not recognized', () {
      const src = 'edit src/Makefile now';
      expect(autolinkMarkdownLinks(src), src);
    });

    test('directory path is not recognized', () {
      const src = 'browse docs/ now';
      expect(autolinkMarkdownLinks(src), src);
    });

    test('prose slash pairs are not recognized', () {
      const src = 'this and/or that, also etc/hosts';
      expect(autolinkMarkdownLinks(src), src);
    });

    test('path match never starts mid-word', () {
      expect(
        autolinkMarkdownLinks('xlib/foo.dart'),
        '[xlib/foo.dart](ob-file:///xlib/foo.dart)',
      );
      const partial = 'pre xlib/foo.dart';
      expect(
        autolinkMarkdownLinks(partial),
        'pre [xlib/foo.dart](ob-file:///xlib/foo.dart)',
      );
    });

    test('line suffix glued to letters rejects the whole match', () {
      const src = 'see lib/foo.dart:42abc now';
      expect(autolinkMarkdownLinks(src), src);
    });

    test('host:port path is not linkified', () {
      const src = 'dev on localhost:8080/a/b.dart or 127.0.0.1:3000/x/y.ts';
      expect(autolinkMarkdownLinks(src), src);
    });

    test('windows drive path is not linkified', () {
      const src = r'C:/Users/x/y.dart and D:\work\z.dart';
      expect(autolinkMarkdownLinks(src), src);
    });

    test('paths inside fenced code are not linkified', () {
      const src = '```\nlib/foo.dart\n```\nlib/bar.dart';
      final out = autolinkMarkdownLinks(src);
      expect(out.contains('[lib/foo.dart]'), isFalse);
      expect(out, contains('[lib/bar.dart](ob-file:///lib/bar.dart)'));
    });

    test('inline code span that is only a path IS linkified', () {
      expect(
        autolinkMarkdownLinks('see `lib/foo.dart` here'),
        'see [lib/foo.dart](ob-file:///lib/foo.dart) here',
      );
      expect(
        autolinkMarkdownLinks('``lib/foo.dart:7``'),
        '[lib/foo.dart:7](ob-file:///lib/foo.dart?line=7)',
      );
    });

    test('inline code path with extra text is kept as code', () {
      const src = 'run `open lib/foo.dart` ok';
      expect(autolinkMarkdownLinks(src), src);
    });

    test('inline code path with spaces is kept as code', () {
      const src = 'see `my dir/foo.dart` here';
      expect(autolinkMarkdownLinks(src), src);
    });

    test('inline code bare domain is kept as code', () {
      const src = '`github.com/org/repo/blob/main/foo.dart`';
      expect(autolinkMarkdownLinks(src), src);
    });

    test('existing markdown link with path target is not double-processed', () {
      const src = '[foo](lib/foo.dart)';
      expect(autolinkMarkdownLinks(src), src);
    });

    test('fast path: no slash and no URI prefix returns input', () {
      const src = 'nothing linkable here at all';
      expect(autolinkMarkdownLinks(src), src);
    });
  });

  group('decodeFileHref', () {
    test('decodes relative path and line', () {
      expect(
        decodeFileHref('ob-file:///lib/foo.dart?line=42'),
        ('lib/foo.dart', 42),
      );
    });

    test('decodes absolute path without line', () {
      expect(
        decodeFileHref('ob-file:////home/u/proj/a.dart'),
        ('/home/u/proj/a.dart', null),
      );
    });

    test('splits query before decoding so encoded ? survives', () {
      expect(
        decodeFileHref('ob-file:///weird%3Fline%3D9/foo.dart'),
        ('weird?line=9/foo.dart', null),
      );
    });

    test('rejects non ob-file hrefs', () {
      expect(decodeFileHref('http://example.com'), isNull);
      expect(decodeFileHref('ob-file:///'), isNull);
    });

    test('rejects malformed percent-encoding', () {
      expect(decodeFileHref('ob-file:///100%/foo.dart'), isNull);
    });
  });

  group('resolveProjectPath', () {
    const dir = '/home/u/proj';

    test('relative path passes through', () {
      expect(resolveProjectPath('lib/foo.dart', dir), 'lib/foo.dart');
    });

    test('dot segments are normalized', () {
      expect(resolveProjectPath('./lib/foo.dart', dir), 'lib/foo.dart');
      expect(resolveProjectPath('lib/../docs/foo.md', dir), 'docs/foo.md');
    });

    test('absolute path inside project is stripped to relative', () {
      expect(
        resolveProjectPath('/home/u/proj/lib/foo.dart', dir),
        'lib/foo.dart',
      );
    });

    test('absolute path outside project is rejected', () {
      expect(resolveProjectPath('/etc/hosts', dir), isNull);
    });

    test('relative path escaping the project is rejected', () {
      expect(resolveProjectPath('../../etc/nginx/nginx.conf', dir), isNull);
      expect(resolveProjectPath('../sibling/a.dart', dir), isNull);
    });

    test('absolute path escaping via dot-dot is rejected', () {
      expect(resolveProjectPath('/home/u/proj/../../etc/x.conf', dir), isNull);
    });

    test('empty directory is rejected', () {
      expect(resolveProjectPath('lib/foo.dart', ''), isNull);
    });
  });
}
