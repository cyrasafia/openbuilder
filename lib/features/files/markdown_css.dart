import 'package:flutter/material.dart';
import 'package:re_highlight/styles/github-dark.dart' as hl;
import 'package:re_highlight/styles/github.dart' as hl;

import '../../ui/theme.dart';

int _channel(double v) => (v * 255.0).round().clamp(0, 255);

String _cssColor(Color c) {
  if (c.a >= 1.0) {
    return '#${_hexByte(_channel(c.r))}${_hexByte(_channel(c.g))}${_hexByte(_channel(c.b))}';
  }
  return 'rgba(${_channel(c.r)},${_channel(c.g)},${_channel(c.b)},'
      '${c.a.toStringAsFixed(3)})';
}

String _hexByte(int v) => v.toRadixString(16).padLeft(2, '0');

const _alertPalette = {
  Brightness.light: {
    'note': ('#0969da', '#ddf4ff'),
    'tip': ('#1a7f37', '#dafbe1'),
    'important': ('#8250df', '#fbefff'),
    'warning': ('#9a6700', '#fff8c5'),
    'caution': ('#cf222e', '#ffebe9'),
  },
  Brightness.dark: {
    'note': ('#4493f8', 'rgba(56,139,253,0.15)'),
    'tip': ('#3fb950', 'rgba(63,185,80,0.15)'),
    'important': ('#ab7df8', 'rgba(171,125,248,0.15)'),
    'warning': ('#d29922', 'rgba(187,128,9,0.15)'),
    'caution': ('#f85149', 'rgba(248,81,73,0.15)'),
  },
};

String _markdownAlertCss(Brightness brightness) {
  final buf = StringBuffer()
    ..write('.markdown-alert{')
    ..write('margin:0 0 10px;padding:8px 12px;border-left:3px solid ')
    ..write('transparent;border-radius:6px;}')
    ..write('.markdown-alert>:last-child{margin-bottom:0;}')
    ..write('.markdown-alert-title{margin:0 0 4px;font-size:12px;')
    ..write('font-weight:600;letter-spacing:0.5px;text-transform:uppercase;}');
  for (final e in _alertPalette[brightness]!.entries) {
    final kind = e.key;
    final (accent, bg) = e.value;
    buf
      ..write('.markdown-alert-$kind{border-left-color:$accent;')
      ..write('background:$bg;}')
      ..write('.markdown-alert-$kind .markdown-alert-title{color:$accent;}');
  }
  return buf.toString();
}

String _sanitizeScope(String scope) =>
    scope.replaceAll('.', '-').replaceAll(':', '-');

String codeHighlightCss(Brightness brightness) {
  final theme = brightness == Brightness.dark
      ? hl.githubDarkTheme
      : hl.githubTheme;
  final buf = StringBuffer();
  theme.forEach((scope, style) {
    if (scope == 'root') return;
    final decls = <String>[];
    if (style.color != null) decls.add('color:${_cssColor(style.color!)}');
    final w = style.fontWeight;
    if (w == FontWeight.bold || w == FontWeight.w700) {
      decls.add('font-weight:600');
    }
    if (decls.isEmpty) return;
    buf.write('.tok-${_sanitizeScope(scope)}{${decls.join(';')}}');
  });
  return buf.toString();
}

String markdownPreviewCss({
  required Brightness brightness,
  required Color scaffoldBg,
  required Color onSurface,
  required AppColors appColors,
}) {
  final bg = _cssColor(scaffoldBg);
  final text = _cssColor(onSurface);
  final link = _cssColor(appColors.link);
  final codeColor = _cssColor(appColors.code);
  final codeBg = _cssColor(appColors.codeBackground);
  final border = _cssColor(appColors.border);
  final quoteBar = _cssColor(appColors.quoteBar);
  final fmKey = _cssColor(onSurface.withValues(alpha: 0.55));

  return '''
:root{
  --bg:$bg;--text:$text;--link:$link;--code:$codeColor;--code-bg:$codeBg;
  --border:$border;--quote-bar:$quoteBar;--fm-key:$fmKey;
}
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent;}
html{background:var(--bg);-webkit-text-size-adjust:100%;text-size-adjust:100%;}
body{
  margin:0;padding:14px 14px 32px;
  background:var(--bg);color:var(--text);
  font-family:-apple-system,BlinkMacSystemFont,"MiSans","Segoe UI",Roboto,sans-serif;
  font-size:14px;font-weight:400;line-height:1.45;
  word-wrap:break-word;overflow-wrap:break-word;
}
.md>:last-child{margin-bottom:0;}
p{margin:0 0 6px;font-size:14px;font-weight:400;line-height:1.45;}
strong,b{font-weight:600;}
em,i{font-style:italic;}
a{color:var(--link);text-decoration:none;-webkit-touch-callout:none;}
h1,h2,h3,h4,h5,h6{font-weight:600;line-height:1.3;margin:18px 0 8px;color:var(--text);}
h1{font-size:24px;}
h2{font-size:22px;}
h3{font-size:20px;}
h4{font-size:18px;}
h5{font-size:16px;}
h6{font-size:14px;}
h1:first-child,h2:first-child,h3:first-child,h4:first-child,
h5:first-child,h6:first-child{margin-top:0;}
ul,ol{margin:0 0 6px;padding-left:24px;}
li{margin:2px 0;}
li>p{margin:0;}
code{
  font-family:monospace,"DejaVu Sans Mono",Menlo,"Courier New",monospace;
  font-size:13px;color:var(--code);
}
pre{
  background:var(--code-bg);border:1px solid var(--border);
  border-radius:8px;padding:12px;margin:0 0 10px;overflow-x:auto;
  -webkit-overflow-scrolling:touch;
}
pre code{
  display:block;font-family:monospace,"DejaVu Sans Mono",Menlo,"Courier New",monospace;
  font-size:13px;font-weight:400;line-height:1.45;color:var(--text);
  white-space:pre;background:transparent;border:0;padding:0;
}
blockquote{
  margin:0 0 10px;padding:2px 0 2px 12px;
  border-left:3px solid var(--quote-bar);color:var(--text);font-style:italic;
}
blockquote>:last-child{margin-bottom:0;}
hr{border:0;border-top:1px solid var(--border);margin:14px 0;}
table{border-collapse:collapse;width:auto;max-width:100%;margin:0 0 10px;display:block;overflow-x:auto;}
th,td{border:1px solid var(--border);padding:6px 10px;text-align:left;}
th{font-weight:600;}
img{max-width:100%;height:auto;}
.frontmatter{
  background:var(--code-bg);border:1px solid var(--border);border-radius:8px;
  padding:10px 12px;margin:0 0 12px;
}
.fm-row{padding:1px 0;}
.fm-row+.fm-row{margin-top:4px;}
.fm-key{
  font-size:11px;font-weight:600;color:var(--fm-key);
  letter-spacing:0.4px;margin-bottom:2px;
}
.fm-val{font-size:13px;line-height:1.4;color:var(--text);word-break:break-word;}
${_markdownAlertCss(brightness)}
${codeHighlightCss(brightness)}
''';
}
