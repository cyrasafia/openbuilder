/// URI autolinker for conversation message markdown.
///
/// Rewrites bare URIs (`http(s)://…`, `ftp://…`, `www.…`) found in free text
/// into clickable markdown links, while leaving content inside fenced code
/// blocks untouched. A backtick code span whose entire content is a single URI
/// (e.g. `` `http://example.com` ``) is also linkified, so a deliberately
/// delimited URL stays clickable; code spans containing anything else are kept
/// verbatim. Existing markdown links `[t](u)` and angle autolinks `<u>` are
/// preserved to avoid double processing. Indented (4-space) code blocks are
/// not detected; fenced blocks are the common case in assistant output.
String autolinkMarkdownUris(String src) {
  if (!src.contains('http') &&
      !src.contains('ftp') &&
      !src.contains('www.')) {
    return src;
  }
  final lines = src.split('\n');
  final out = <String>[];
  var inFence = false;
  var fenceChar = '';
  var fenceLen = 0;
  for (final raw in lines) {
    final stripped = raw.replaceFirst(RegExp(r'[ \t\r]+$'), '');
    final delim = _fenceDelimiter.firstMatch(stripped);
    if (inFence) {
      out.add(raw);
      if (delim != null) {
        final c = delim.group(1)!;
        if (c[0] == fenceChar &&
            c.length >= fenceLen &&
            stripped.substring(delim.end).isEmpty) {
          inFence = false;
        }
      }
      continue;
    }
    if (delim != null) {
      final c = delim.group(1)!;
      inFence = true;
      fenceChar = c[0];
      fenceLen = c.length;
      out.add(raw);
      continue;
    }
    out.add(_autolinkLine(raw));
  }
  return out.join('\n');
}

final RegExp _fenceDelimiter = RegExp(r'^ {0,3}(`{3,}|~{3,})');

final RegExp _inlineToken = RegExp([
  r"""`{2,}[^`\n]*`{2,}""",
  r"""`[^`\n]*`""",
  r"""\[[^\]\n]*\]\([^)\n]*\)""",
  r"""<[^<>\s\n]+>""",
  r"""(?<![A-Za-z0-9_])(?:https?|ftp)://[^\s<>"'`\[\]]+""",
  r"""(?<![A-Za-z0-9_])www\.[A-Za-z0-9][^\s<>"'`\[\]]+""",
].join('|'));

final RegExp _uriScheme = RegExp(r'^(?:https?|ftp)://|^www\.');
final RegExp _whitespace = RegExp(r'\s');

String _autolinkLine(String line) {
  return line.replaceAllMapped(_inlineToken, (m) {
    final t = m.group(0)!;
    switch (t[0]) {
      case '`':
        var open = 0;
        while (open < t.length && t.codeUnitAt(open) == 0x60) {
          open++;
        }
        var close = 0;
        while (close < t.length - open &&
            t.codeUnitAt(t.length - 1 - close) == 0x60) {
          close++;
        }
        if (open != close) return t;
        final inner = t.substring(open, t.length - open).trim();
        if (_isSingleUri(inner)) {
          return '[$inner](${_destination(inner)})';
        }
        return t;
      case '[':
      case '<':
        return t;
      default:
        final url = _trimTrailing(t);
        final tail = t.substring(url.length);
        return '[$url](${_destination(url)})$tail';
    }
  });
}

bool _isSingleUri(String s) {
  if (s.isEmpty || _whitespace.hasMatch(s)) return false;
  return _uriScheme.hasMatch(s);
}

String _destination(String url) => url.startsWith('www.') ? 'https://$url' : url;

String _trimTrailing(String url) {
  var u = url;
  const punct = '.,;:!?';
  while (u.length > 1 && punct.contains(u[u.length - 1])) {
    u = u.substring(0, u.length - 1);
  }
  while (u.length > 1 && u.endsWith(')')) {
    final opens = '('.allMatches(u).length;
    final closes = ')'.allMatches(u).length;
    if (closes > opens) {
      u = u.substring(0, u.length - 1);
    } else {
      break;
    }
  }
  return u;
}
