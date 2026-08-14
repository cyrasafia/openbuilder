/// Link autolinker for conversation message markdown.
///
/// Rewrites bare link targets found in free text into clickable markdown
/// links: URIs (`http(s)://…`, `ftp://…`, `www.…`) and project file paths
/// (`lib/foo.dart`, `/abs/proj/lib/foo.dart`, optional `:line(:col)` suffix).
/// Content inside fenced code blocks is left untouched. A backtick code span
/// whose entire content is a single link target (e.g. `` `http://example.com`
/// `` or `` `lib/foo.dart` ``) is also linkified; code spans containing
/// anything else are kept verbatim. Existing markdown links `[t](u)` and
/// angle autolinks `<u>` are preserved to avoid double processing. Indented
/// (4-space) code blocks are not detected; fenced blocks are the common case
/// in assistant output.
///
/// File paths are rewritten to `ob-file:///<path>?line=N` hrefs; the tap
/// handler routes `ob-file:` to the file browsing container and everything
/// else to the external browser. Paths must contain `/`, must not contain
/// spaces, and the final segment must carry an extension (`name.ext`) or be
/// a dotfile (`.gitignore`) — single-segment names, directories and
/// extension-less files (`Makefile`) are not recognized, to keep false
/// positives acceptable without any filesystem existence check.
library;

String autolinkMarkdownLinks(String src) {
  if (!src.contains('http') &&
      !src.contains('ftp') &&
      !src.contains('www.') &&
      !src.contains('/')) {
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

const _segment = r'[A-Za-z0-9_@+.-]+';
const _terminalSeg =
    r'(?:[A-Za-z0-9_@+.-]+\.[A-Za-z0-9]{1,10}|\.[A-Za-z0-9][A-Za-z0-9_@+.-]*)'
    r'(?![A-Za-z0-9])';
const _lineSuffix = r'(?::\d+(?::\d+)?)?(?![A-Za-z0-9:])';
const _absPath =
    '(?<![A-Za-z0-9_/.:])/(?:$_segment/)+$_terminalSeg$_lineSuffix';
const _relPath =
    '(?<![A-Za-z0-9_/.:])(?:\\.{1,2}/)?(?:$_segment/)+$_terminalSeg$_lineSuffix';

final RegExp _inlineToken = RegExp([
  r"""`{2,}[^`\n]*`{2,}""",
  r"""`[^`\n]*`""",
  r"""\[[^\]\n]*\]\([^)\n]*\)""",
  r"""<[^<>\s\n]+>""",
  r"""(?<![A-Za-z0-9_])(?:https?|ftp)://[^\s<>"'`\[\]]+""",
  r"""(?<![A-Za-z0-9_])www\.[A-Za-z0-9][^\s<>"'`\[\]]+""",
  _absPath,
  _relPath,
].join('|'));

final RegExp _uriScheme = RegExp(r'^(?:https?|ftp)://|^www\.');
final RegExp _whitespace = RegExp(r'\s');
final RegExp _singleFilePath = RegExp('^(?:$_absPath|$_relPath)\$');
final RegExp _lineSuffixRe = RegExp(r':(\d+)(?::\d+)?$');
final RegExp _bareDomainTld = RegExp(
  r'\.(?:com|org|net|io|dev|app|co|cn|me|xyz)$',
  caseSensitive: false,
);

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
        final file = _parseFilePath(inner);
        if (file != null && !_isBareDomain(file.$1)) {
          return '[$inner](${fileHref(file.$1, file.$2)})';
        }
        return t;
      case '[':
      case '<':
        return t;
      default:
        if (_uriScheme.hasMatch(t)) {
          final url = _trimTrailing(t);
          final tail = t.substring(url.length);
          return '[$url](${_destination(url)})$tail';
        }
        final file = _parseFilePath(t);
        if (file == null || _isBareDomain(file.$1)) return t;
        return '[$t](${fileHref(file.$1, file.$2)})';
    }
  });
}

bool _isSingleUri(String s) {
  if (s.isEmpty || _whitespace.hasMatch(s)) return false;
  return _uriScheme.hasMatch(s);
}

(String, int?)? _parseFilePath(String s) {
  if (s.isEmpty || _whitespace.hasMatch(s)) return null;
  final lm = _lineSuffixRe.firstMatch(s);
  final path = lm == null ? s : s.substring(0, lm.start);
  final line = lm == null ? null : int.tryParse(lm.group(1)!);
  if (!_singleFilePath.hasMatch(path)) return null;
  return (path, line);
}

bool _isBareDomain(String path) {
  if (path.startsWith('/')) return false;
  final first = path.split('/').first;
  return _bareDomainTld.hasMatch(first);
}

String _destination(String url) => url.startsWith('www.') ? 'https://$url' : url;

String fileHref(String path, int? line) {
  final encoded = path.split('/').map(Uri.encodeComponent).join('/');
  return 'ob-file:///$encoded${line != null ? '?line=$line' : ''}';
}

(String, int?)? decodeFileHref(String href) {
  const prefix = 'ob-file:///';
  if (!href.startsWith(prefix)) return null;
  var s = href.substring(prefix.length);
  int? line;
  final q = s.indexOf('?');
  if (q >= 0) {
    final query = s.substring(q + 1);
    s = s.substring(0, q);
    if (query.startsWith('line=')) {
      line = int.tryParse(query.substring(5));
    }
  }
  final String path;
  try {
    path = Uri.decodeComponent(s);
  } on ArgumentError {
    return null;
  }
  if (path.isEmpty) return null;
  return (path, line);
}

String? resolveProjectPath(String path, String directory) {
  if (directory.isEmpty) return null;
  final rel = path.startsWith('/') ? _stripProjectRoot(path, directory) : path;
  if (rel == null) return null;
  return _normalizeRelative(rel);
}

String? _stripProjectRoot(String abs, String directory) {
  final prefix = directory.endsWith('/') ? directory : '$directory/';
  if (!abs.startsWith(prefix)) return null;
  return abs.substring(prefix.length);
}

String? _normalizeRelative(String rel) {
  final out = <String>[];
  for (final seg in rel.split('/')) {
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') {
      if (out.isEmpty) return null;
      out.removeLast();
    } else {
      out.add(seg);
    }
  }
  if (out.isEmpty) return null;
  return out.join('/');
}

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
