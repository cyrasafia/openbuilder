import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/features/files/html_preview.dart';

void main() {
  group('buildHtmlPreviewDocument', () {
    test('injects CSP and viewport right after <head>', () {
      final doc = buildHtmlPreviewDocument(
        '<!DOCTYPE html><html><head><title>t</title></head>'
        '<body><p>hi</p></body></html>',
      );
      final csp = doc.indexOf('Content-Security-Policy');
      final viewport = doc.indexOf('name="viewport"');
      final title = doc.indexOf('<title>');
      expect(csp, greaterThanOrEqualTo(0));
      expect(csp, lessThan(title));
      expect(viewport, greaterThan(csp));
      expect(viewport, lessThan(title));
      // The document's own markup is preserved verbatim.
      expect(doc, contains('<title>t</title>'));
      expect(doc, contains('<body><p>hi</p></body>'));
    });

    test('ships the restrictive markdown-preview CSP (scripts inert)', () {
      final doc = buildHtmlPreviewDocument('<html><body>x</body></html>');
      expect(doc, contains("default-src 'none'"));
      expect(doc, contains("style-src 'unsafe-inline'"));
      // no script-src carve-out — raw <script> in the file stays inert
      expect(doc, isNot(contains('script-src')));
    });

    test('creates a head when only <html> exists', () {
      final doc = buildHtmlPreviewDocument(
        '<html lang="en"><body><p>x</p></body></html>',
      );
      expect(doc, contains('<head><meta http-equiv'));
      expect(doc.indexOf('<head>'), lessThan(doc.indexOf('<body>')));
      expect(doc, contains('lang="en"'));
    });

    test('prepends metas for headless fragments', () {
      final doc = buildHtmlPreviewDocument('<div>frag</div>');
      expect(doc, startsWith('<meta http-equiv'));
      expect(doc, endsWith('<div>frag</div>'));
    });

    test('skips the viewport meta when the document declares one', () {
      final doc = buildHtmlPreviewDocument(
        '<html><head><meta name="viewport" content="width=800">'
        '</head><body></body></html>',
      );
      expect(doc, isNot(contains('initial-scale')));
      expect(doc, contains('Content-Security-Policy'));
    });

    test('matches <HEAD>/<HTML> case-insensitively', () {
      final doc = buildHtmlPreviewDocument(
        '<HTML><HEAD><TITLE>t</TITLE></HEAD><BODY></BODY></HTML>',
      );
      final csp = doc.indexOf('Content-Security-Policy');
      expect(csp, greaterThan(doc.indexOf('<HEAD>')));
      expect(csp, lessThan(doc.indexOf('<TITLE>')));
    });

    test('skips a <head> that only appears inside a comment', () {
      final doc = buildHtmlPreviewDocument(
        '<!-- saved page <head>old</head> -->'
        '<html><head><title>t</title></head></html>',
      );
      final csp = doc.indexOf('Content-Security-Policy');
      expect(csp, greaterThan(doc.indexOf('-->')));
      expect(csp, lessThan(doc.indexOf('<title>')));
    });

    test('skips a literal <head> inside script raw text', () {
      final doc = buildHtmlPreviewDocument(
        '<html><script>var s = "<head>fake</head>";</script>'
        '<head><title>t</title></head></html>',
      );
      final csp = doc.indexOf('Content-Security-Policy');
      expect(csp, greaterThan(doc.indexOf('</script>')));
      expect(csp, lessThan(doc.indexOf('<title>')));
    });

    test('skips a literal <head> inside a title', () {
      // Malformed doc with no real head: the only <head> literal sits in
      // title raw text, so the injection must fall through to the <html>
      // branch — a meta injected inside <title> would render as the page
      // title and never apply.
      final doc = buildHtmlPreviewDocument(
        '<html><title>about the <head> tag</title><body>x</body></html>',
      );
      final csp = doc.indexOf('Content-Security-Policy');
      expect(csp, greaterThan(doc.indexOf('<html>')));
      expect(csp, lessThan(doc.indexOf('<title>')));
      expect(doc, contains('<head><meta http-equiv'));
    });

    test('commented-out viewport meta does not suppress injection', () {
      final doc = buildHtmlPreviewDocument(
        '<html><head><!-- <meta name="viewport" content="width=800"> -->'
        '</head><body></body></html>',
      );
      expect(doc, contains('initial-scale'));
      expect(doc.indexOf('initial-scale'), lessThan(doc.indexOf('<!--')));
    });
    test('falls back to prepending when every head-like match is inactive', () {
      final doc = buildHtmlPreviewDocument(
        '<!-- <html><head>all commented</head></html> --><div>frag</div>',
      );
      expect(doc, startsWith('<meta http-equiv'));
      expect(doc, endsWith('<div>frag</div>'));
    });

    test('skips a literal <head> inside <xmp> raw text', () {
      // The reviewer's crafted case: without the xmp entry the CSP would be
      // injected inside the raw text and the trailing script would run
      // unrestrained.
      final doc = buildHtmlPreviewDocument(
        '<html><body><xmp><head></xmp><script>alert(1)</script></body></html>',
      );
      expect(
        doc.indexOf('<head><meta http-equiv'),
        doc.indexOf('<html>') + '<html>'.length,
      );
    });

    test('skips a literal <head> inside <noscript> raw text', () {
      // noscript is raw text while scripting is enabled — always the case in
      // this WebView.
      final doc = buildHtmlPreviewDocument(
        '<html><body><noscript><head></noscript></body></html>',
      );
      expect(
        doc.indexOf('<head><meta http-equiv'),
        doc.indexOf('<html>') + '<html>'.length,
      );
    });

    test('<plaintext> swallows the rest of the file', () {
      final doc = buildHtmlPreviewDocument(
        '<html><body><plaintext><head>x</head></body></html>',
      );
      expect(
        doc.indexOf('<head><meta http-equiv'),
        doc.indexOf('<html>') + '<html>'.length,
      );
    });

    test('recognizes an unquoted viewport meta and skips injection', () {
      final doc = buildHtmlPreviewDocument(
        '<html><head><meta name=viewport content="width=800"></head>'
        '<body></body></html>',
      );
      expect(doc, isNot(contains('initial-scale')));
      expect(doc, contains('Content-Security-Policy'));
    });

    test('does not mistake SVG <metadata> for a viewport declaration', () {
      final doc = buildHtmlPreviewDocument(
        '<metadata name="viewport">x</metadata>',
      );
      expect(doc, contains('initial-scale'));
    });

    test('a data-name attribute is not a viewport declaration', () {
      final doc = buildHtmlPreviewDocument(
        '<html><head><meta data-name="viewport"></head><body></body></html>',
      );
      expect(doc, contains('initial-scale'));
    });

    test('a viewport meta inside <template> does not suppress injection', () {
      final doc = buildHtmlPreviewDocument(
        '<html><head><template><meta name="viewport" content="w"></template>'
        '</head><body></body></html>',
      );
      expect(doc, contains('initial-scale'));
    });

    test('skips a literal <head> inside a <?…> bogus comment', () {
      // PHP-ish server-side block: the tokenizer treats <? … > as a bogus
      // comment ending at the first >, so the <head> inside never parses.
      final doc = buildHtmlPreviewDocument(
        '<? inject <head> placeholder ?>'
        '<html><head><title>t</title></head></html>',
      );
      final csp = doc.indexOf('Content-Security-Policy');
      expect(csp, greaterThan(doc.indexOf('?>')));
      expect(csp, lessThan(doc.indexOf('<title>')));
    });

    test('skips a literal <head> inside a <!…> bogus comment', () {
      final doc = buildHtmlPreviewDocument(
        '<html><!bogus <head> text><head><title>t</title></head></html>',
      );
      final csp = doc.indexOf('Content-Security-Policy');
      expect(csp, greaterThan(doc.indexOf('<!bogus')));
      expect(csp, lessThan(doc.indexOf('<title>')));
    });

    test('a doctype before <html> does not disturb the injection point', () {
      final doc = buildHtmlPreviewDocument(
        '<!DOCTYPE html><html><head><title>t</title></head></html>',
      );
      final csp = doc.indexOf('Content-Security-Policy');
      expect(csp, greaterThan(doc.indexOf('<html>')));
      expect(csp, lessThan(doc.indexOf('<title>')));
    });

    test('</scriptx> inside script data does not end the raw-text region', () {
      // Per the tokenizer, `</script` must be followed by whitespace, `/` or
      // `>` to close; closing early would expose the later literal <head>
      // (still inside the script) as an active injection point and silently
      // drop the CSP.
      final doc = buildHtmlPreviewDocument(
        '<script>var a = "</scriptx <head>";</script>',
      );
      expect(doc, startsWith('<meta http-equiv'));
      expect(doc, endsWith('<script>var a = "</scriptx <head>";</script>'));
    });

    test('attribute-value <head> literal is skipped via the tag region', () {
      final doc = buildHtmlPreviewDocument(
        '<html><body><div title="<head>x"></div></body></html>',
      );
      final csp = doc.indexOf('Content-Security-Policy');
      expect(csp, greaterThan(doc.indexOf('<html>')));
      expect(doc, contains('<head><meta http-equiv'));
    });

    test('dense comment documents classify correctly', () {
      final padding = '<!-- c -->' * 20000;
      final doc = buildHtmlPreviewDocument(
        '$padding<html><head><title>t</title></head></html>',
      );
      final csp = doc.indexOf('Content-Security-Policy');
      expect(csp, greaterThan(doc.indexOf('<html>')));
      expect(csp, lessThan(doc.indexOf('<title>')));
    });

    test('over-cap content skips the scan and prepends the metas', () {
      final fill = '<!--${'x' * (scanCap + 100)}-->';
      final doc = buildHtmlPreviewDocument(
        '$fill<html><head><title>t</title></head></html>',
      );
      expect(doc, startsWith('<meta http-equiv'));
      expect(doc, endsWith('</html>'));
    });
  });
}
