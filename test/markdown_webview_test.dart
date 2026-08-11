import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/features/files/highlight_theme.dart';
import 'package:open_builder/features/files/markdown_css.dart';
import 'package:open_builder/features/files/markdown_html.dart';
import 'package:open_builder/ui/theme.dart';

void main() {
  group('HighlightPainter.highlightToHtml', () {
    test('wraps tokens in tok-* spans and escapes HTML', () {
      final html = HighlightPainter.highlightToHtml(
        "var s = '<b>';", 'dart',
      );
      expect(html, contains('tok-'));
      // raw < > must be escaped, never emitted as live tags
      expect(html, contains('&lt;b&gt;'));
      expect(html.contains('<b>'), isFalse);
    });

    test('falls back to escaped plain text for empty language', () {
      final html = HighlightPainter.highlightToHtml('a < b & c', '');
      expect(html, 'a &lt; b &amp; c');
    });

    test('falls back for an unknown language without throwing', () {
      final html = HighlightPainter.highlightToHtml('x = 1', 'totally_unknown');
      expect(html, 'x = 1');
    });
  });

  group('codeHighlightCss', () {
    test('emits a rule per token scope (sans root) for both themes', () {
      for (final b in Brightness.values) {
        final css = codeHighlightCss(b);
        expect(css, contains('.tok-keyword'));
        expect(css, contains('.tok-string'));
        expect(css, contains('.tok-comment'));
        // root is handled by the container, not a token class
        expect(css, isNot(contains('.tok-root')));
      }
    });

    test('only ever uses the three allowed font weights', () {
      for (final b in Brightness.values) {
        final css = codeHighlightCss(b);
        expect(css, isNot(contains('font-weight:500')));
        expect(css, isNot(contains('font-weight:700')));
        expect(css, isNot(contains('bold')));
      }
    });
  });

  group('markdownPreviewCss', () {
    String cssFor(Brightness b) => markdownPreviewCss(
          brightness: b,
          scaffoldBg: b == Brightness.dark
              ? const Color(0xFF0E0F12)
              : const Color(0xFFF7F8FA),
          onSurface: const Color(0xFFDFE4DC),
          appColors: b == Brightness.dark ? AppColors.dark : AppColors.light,
        );

    test('enforces the DESIGN.md three-tier weight scale', () {
      for (final b in Brightness.values) {
        final css = cssFor(b);
        // Regular (400) and Semi Bold (600) are both exercised by the doc
        // stylesheet; Light (300) is reserved for hero titles and has no
        // place in body content, so it may legitimately be absent.
        expect(css, contains('font-weight:400'));
        expect(css, contains('font-weight:600'));
        // Forbidden weights / aliases must never appear.
        expect(css, isNot(contains('font-weight:500')));
        expect(css, isNot(contains('font-weight:700')));
        expect(css, isNot(contains(':bold')));
        expect(css, isNot(contains('font-weight:normal')));
      }
    });

    test('maps AppColors tokens and uses monospace for code', () {
      final css = cssFor(Brightness.dark);
      expect(css, contains('--link:#2196f3'));
      expect(css, contains('--code-bg:#161b22'));
      expect(css, contains('--border:#30363d'));
      expect(css, contains('--quote-bar:#6e7681'));
      expect(css, contains('font-family:monospace'));
    });
  });

  group('resolveRelativePath', () {
    test('resolves a sibling relative link', () {
      expect(resolveRelativePath('bar.md', 'docs/foo.md'), 'docs/bar.md');
    });

    test('resolves a parent-relative link', () {
      expect(resolveRelativePath('../bar.md', 'docs/sub/foo.md'),
          'docs/bar.md');
    });

    test('strips a leading slash for absolute workspace paths', () {
      expect(resolveRelativePath('/docs/bar.md', 'docs/foo.md'),
          'docs/bar.md');
    });

    test('resolves at repo root', () {
      expect(resolveRelativePath('bar.md', 'foo.md'), 'bar.md');
    });
  });

  group('buildMarkdownPreviewHtml', () {
    String docFor(String content) => buildMarkdownPreviewHtml(
          content: content,
          brightness: Brightness.dark,
          scaffoldBg: const Color(0xFF0E0F12),
          onSurface: const Color(0xFFDFE4DC),
          appColors: AppColors.dark,
        );

    test('emits a viewport meta and inline style', () {
      final html = docFor('# Hi');
      expect(html, startsWith('<!DOCTYPE html>'));
      expect(html, contains('name="viewport"'));
      expect(html, contains('<style>'));
    });

    test('ships a restrictive CSP that blocks scripts/iframes/external', () {
      final html = docFor('# Hi');
      expect(html, contains('Content-Security-Policy'));
      expect(html, contains("default-src 'none'"));
      // scripts must be denied (no script-src carve-out) so raw <script>
      // passed through by package:markdown is inert.
      expect(html, isNot(contains('script-src')));
    });

    test('renders front matter as a metadata card and strips it from body', () {
      final html = docFor('---\ntitle: Hello\nauthor: cyra\n---\n\n# Body');
      expect(html, contains('class="frontmatter"'));
      expect(html, contains('class="fm-key">title'));
      expect(html, contains('class="fm-val">Hello'));
      // The card must precede the body heading…
      expect(html.indexOf('class="frontmatter"'),
          lessThan(html.indexOf('<h1')));
      // …and the raw YAML fence must not leak into the rendered body.
      expect(html, isNot(contains('author: cyra')));
    });

    test('highlights fenced code blocks with tok-* spans', () {
      final html = docOfLang('dart');
      // the code block is present and got highlighted markup inside <pre>
      expect(html, contains('<pre><code'));
      expect(html, contains('tok-'));
      // unescaped angle brackets in code must be escaped in output
      expect(html, contains('&lt;'));
    });

    test('keeps unknown-language code blocks as escaped plain text', () {
      final html = docOfLang('totally_unknown');
      expect(html, contains('<pre><code'));
      // the code content is escaped plain text — no token <span> wraps it.
      expect(html, contains('>a &lt; b</code>'));
      final body = html.substring(html.indexOf('<body>'));
      expect(body, isNot(contains('<span class="tok-')));
    });
  });
}

String docOfLang(String lang) => buildMarkdownPreviewHtml(
      content: '```$lang\na < b\n```\n',
      brightness: Brightness.dark,
      scaffoldBg: const Color(0xFF0E0F12),
      onSurface: const Color(0xFFDFE4DC),
      appColors: AppColors.dark,
    );
