import 'package:flutter/material.dart';
import 'package:re_highlight/languages/bash.dart';
import 'package:re_highlight/languages/css.dart';
import 'package:re_highlight/languages/dart.dart';
import 'package:re_highlight/languages/go.dart';
import 'package:re_highlight/languages/javascript.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/languages/markdown.dart';
import 'package:re_highlight/languages/python.dart';
import 'package:re_highlight/languages/rust.dart';
import 'package:re_highlight/languages/shell.dart';
import 'package:re_highlight/languages/sql.dart';
import 'package:re_highlight/languages/typescript.dart';
import 'package:re_highlight/languages/xml.dart';
import 'package:re_highlight/languages/yaml.dart';
import 'package:re_highlight/re_highlight.dart';
import 'package:re_highlight/styles/github.dart' as hl;
import 'package:re_highlight/styles/github-dark.dart' as hl;

const extensionLanguageMap = <String, String>{
  '.dart': 'dart',
  '.ts': 'typescript', '.tsx': 'typescript',
  '.js': 'javascript', '.jsx': 'javascript', '.mjs': 'javascript',
  '.py': 'python',
  '.go': 'go',
  '.rs': 'rust',
  '.json': 'json', '.jsonc': 'json', '.jsonl': 'json',
  '.yaml': 'yaml', '.yml': 'yaml',
  '.md': 'markdown', '.markdown': 'markdown',
  '.sh': 'shell', '.bash': 'shell', '.zsh': 'shell',
  '.sql': 'sql',
  '.html': 'html', '.htm': 'html',
  '.css': 'css',
};

String? languageForPath(String path) {
  final dot = path.lastIndexOf('.');
  if (dot < 0) return null;
  return extensionLanguageMap[path.substring(dot).toLowerCase()];
}

Map<String, TextStyle> _themeFor(Brightness brightness) {
  final raw =
      brightness == Brightness.dark ? hl.githubDarkTheme : hl.githubTheme;
  return {
    for (final e in raw.entries) e.key: _normalizeWeight(e.value),
  };
}

TextStyle _normalizeWeight(TextStyle s) {
  if (s.fontWeight == FontWeight.bold) {
    return s.copyWith(fontWeight: FontWeight.w600);
  }
  return s;
}

final class HighlightPainter {
  HighlightPainter._();

  static final Highlight _hl = _build();

  static Highlight _build() {
    final h = Highlight();
    h.registerLanguages({
      'dart': langDart,
      'typescript': langTypescript,
      'javascript': langJavascript,
      'python': langPython,
      'go': langGo,
      'rust': langRust,
      'json': langJson,
      'yaml': langYaml,
      'markdown': langMarkdown,
      'shell': langShell,
      'bash': langBash,
      'sql': langSql,
      'xml': langXml,
      'css': langCss,
    });
    h.registerAliases('html', 'xml');
    return h;
  }

  static List<TextSpan> highlight(
    String code,
    String language,
    TextStyle base,
    Brightness brightness,
  ) {
    final TextSpan root;
    try {
      final result = _hl.highlight(code: code, language: language);
      final renderer = TextSpanRenderer(base, _themeFor(brightness));
      result.render(renderer);
      root = renderer.span ?? TextSpan(text: code, style: base);
    } catch (_) {
      return _plainLines(code, base);
    }

    final flat = <_FlatSpan>[];
    _flatten(root, base, flat);

    final lines = <List<InlineSpan>>[<InlineSpan>[]];
    for (final fs in flat) {
      final parts = fs.text.split('\n');
      for (var i = 0; i < parts.length; i++) {
        if (i > 0) lines.add(<InlineSpan>[]);
        if (parts[i].isNotEmpty) {
          lines.last.add(TextSpan(text: parts[i], style: fs.style));
        }
      }
    }

    return [
      for (final children in lines)
        children.isEmpty
            ? TextSpan(text: '', style: base)
            : TextSpan(children: children, style: base),
    ];
  }

  static void _flatten(InlineSpan span, TextStyle parentStyle, List<_FlatSpan> out) {
    final style = span.style != null
        ? parentStyle.merge(span.style!)
        : parentStyle;
    if (span is! TextSpan) return;
    final text = span.text;
    final children = span.children;
    if (text != null && text.isNotEmpty) {
      out.add(_FlatSpan(text, style));
    }
    if (children != null) {
      for (final child in children) {
        _flatten(child, style, out);
      }
    }
  }

  static List<TextSpan> _plainLines(String code, TextStyle base) {
    return [
      for (final line in code.split('\n')) TextSpan(text: line, style: base),
    ];
  }
}

final class _FlatSpan {
  const _FlatSpan(this.text, this.style);
  final String text;
  final TextStyle style;
}
