import 'dart:convert';

import 'package:flutter/material.dart';

import 'code_view.dart';
import 'highlight_theme.dart';

enum JsonNodeKind { object, array, string, number, boolean, nullValue }

class JsonTreeNode {
  final String? key;
  final JsonNodeKind kind;
  final List<JsonTreeNode> children;
  final Object? value;
  final int depth;

  JsonTreeNode._(
    this.key,
    this.kind,
    this.children,
    this.value,
    this.depth,
  );

  factory JsonTreeNode.object(
    String? key,
    List<JsonTreeNode> children,
    int depth,
  ) =>
      JsonTreeNode._(key, JsonNodeKind.object, children, null, depth);

  factory JsonTreeNode.array(
    String? key,
    List<JsonTreeNode> children,
    int depth,
  ) =>
      JsonTreeNode._(key, JsonNodeKind.array, children, null, depth);

  factory JsonTreeNode.scalar(
    JsonNodeKind kind,
    String? key,
    Object? value,
    int depth,
  ) =>
      JsonTreeNode._(key, kind, const [], value, depth);

  bool get isContainer =>
      kind == JsonNodeKind.object || kind == JsonNodeKind.array;

  /// Only non-empty containers can expand; empty ones (`{}` / `[]`) render
  /// inline and never take part in the expand state.
  bool get expandable => isContainer && children.isNotEmpty;
}

class JsonParseResult {
  final bool ok;
  final List<JsonTreeNode> roots;
  final int nodeCount;

  const JsonParseResult.ok(this.roots, {required this.nodeCount})
      : ok = true;

  const JsonParseResult.failed()
      : ok = false,
        roots = const [],
        nodeCount = 0;
}

/// Isolate entry: text → tree. Tries a whole-document decode first; on
/// failure, JSONL input falls back to one decode per non-empty line (each
/// line becomes a root). Any other failure — including a bad line in JSONL —
/// yields [JsonParseResult.failed], which the caller maps to source mode.
JsonParseResult parseJsonTreeOffIsolate((String, bool) task) {
  final (text, jsonl) = task;
  try {
    final root = _convertRoot(jsonDecode(text));
    return JsonParseResult.ok([root], nodeCount: _countNodes([root]));
  } catch (_) {
    if (!jsonl) return const JsonParseResult.failed();
  }
  final roots = <JsonTreeNode>[];
  for (final line in text.split('\n')) {
    final t = line.trim();
    if (t.isEmpty) continue;
    try {
      roots.add(_convertRoot(jsonDecode(t)));
    } catch (_) {
      return const JsonParseResult.failed();
    }
  }
  if (roots.isEmpty) return const JsonParseResult.failed();
  return JsonParseResult.ok(roots, nodeCount: _countNodes(roots));
}

JsonTreeNode _convertRoot(dynamic v) => _convert(v, null, 0);

JsonTreeNode _convert(dynamic v, String? key, int depth) {
  if (v is Map) {
    final children = <JsonTreeNode>[
      for (final e in v.entries) _convert(e.value, e.key as String, depth + 1),
    ];
    return JsonTreeNode.object(key, children, depth);
  }
  if (v is List) {
    final children = <JsonTreeNode>[
      for (final e in v) _convert(e, null, depth + 1),
    ];
    return JsonTreeNode.array(key, children, depth);
  }
  final kind = switch (v) {
    String() => JsonNodeKind.string,
    num() => JsonNodeKind.number,
    bool() => JsonNodeKind.boolean,
    _ => JsonNodeKind.nullValue,
  };
  return JsonTreeNode.scalar(kind, key, v, depth);
}

int _countNodes(List<JsonTreeNode> roots) {
  var n = 0;
  void walk(JsonTreeNode node) {
    n++;
    for (final c in node.children) {
      walk(c);
    }
  }

  for (final r in roots) {
    walk(r);
  }
  return n;
}

/// Above this node count the default expansion stays at the first level
/// (same view as collapse-all); below it the tree mounts fully expanded.
const jsonExpandAllNodeCap = 2000;

class JsonTreeRow {
  final JsonTreeNode node;

  /// True for a container's closing-bracket line, false for the node's own
  /// line.
  final bool isClose;

  const JsonTreeRow(this.node, {required this.isClose});
}

class JsonTreeController extends ChangeNotifier {
  final List<JsonTreeNode> roots;

  /// Nodes whose children are currently visible. An identity set — nodes are
  /// compared by reference, never by value.
  final Set<JsonTreeNode> _expanded = Set<JsonTreeNode>.identity();

  List<JsonTreeRow> _rows = const [];

  JsonTreeController({required this.roots, bool expandAll = true}) {
    if (expandAll) {
      _walkAll(_expanded.add);
    } else {
      for (final r in roots) {
        if (r.expandable) _expanded.add(r);
      }
    }
    _rebuildRows();
  }

  List<JsonTreeRow> get rows => _rows;

  bool isExpanded(JsonTreeNode node) => _expanded.contains(node);

  void toggle(JsonTreeNode node) {
    if (!node.expandable) return;
    if (!_expanded.remove(node)) _expanded.add(node);
    _rebuildRows();
    notifyListeners();
  }

  void expandAll() {
    _walkAll(_expanded.add);
    _rebuildRows();
    notifyListeners();
  }

  /// Collapse to the first level: keep only the roots expanded so the
  /// document's top level stays visible.
  void collapseAll() {
    _expanded.clear();
    for (final r in roots) {
      if (r.expandable) _expanded.add(r);
    }
    _rebuildRows();
    notifyListeners();
  }

  void _walkAll(void Function(JsonTreeNode) visit) {
    void walk(JsonTreeNode node) {
      visit(node);
      for (final c in node.children) {
        walk(c);
      }
    }

    for (final r in roots) {
      walk(r);
    }
  }

  void _rebuildRows() {
    final rows = <JsonTreeRow>[];
    void walk(JsonTreeNode node) {
      rows.add(JsonTreeRow(node, isClose: false));
      if (node.expandable && _expanded.contains(node)) {
        for (final c in node.children) {
          walk(c);
        }
        rows.add(JsonTreeRow(node, isClose: true));
      }
    }

    for (final r in roots) {
      walk(r);
    }
    _rows = rows;
  }
}

const _indentPerDepth = 16.0;
const _chevronExtent = 18.0;
const _chevronGap = 4.0;

class JsonTreeView extends StatelessWidget {
  final JsonTreeController controller;
  final ScrollController? scrollController;

  const JsonTreeView({
    super.key,
    required this.controller,
    this.scrollController,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rowHeight =
        MediaQuery.textScalerOf(context).scale(codeFontSize) * codeLineHeight;
    final styles = _RowStyles(theme);
    return ListenableBuilder(
      listenable: controller,
      builder: (_, _) => ListView.builder(
        controller: scrollController,
        itemExtent: rowHeight,
        padding: const EdgeInsets.symmetric(
          horizontal: 8,
          vertical: codeListVerticalPadding,
        ),
        itemCount: controller.rows.length,
        itemBuilder: (_, i) =>
            _buildRow(context, theme, styles, controller.rows[i], rowHeight),
      ),
    );
  }

  Widget _buildRow(
    BuildContext context,
    ThemeData theme,
    _RowStyles styles,
    JsonTreeRow row,
    double rowHeight,
  ) {
    final theme = Theme.of(context);
    final node = row.node;
    final expandable = node.expandable;
    return InkWell(
      onTap: expandable ? () => controller.toggle(node) : null,
      child: SizedBox(
        height: rowHeight,
        child: Row(
          children: [
            SizedBox(width: node.depth * _indentPerDepth),
            SizedBox(
              width: _chevronExtent,
              child: expandable
                  ? Icon(
                      controller.isExpanded(node)
                          ? Icons.expand_more
                          : Icons.chevron_right,
                      size: _chevronExtent,
                      color: theme.colorScheme.outline,
                    )
                  : null,
            ),
            const SizedBox(width: _chevronGap),
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: _rowSpans(row, theme, styles),
                  style: codeTextStyle(),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                strutStyle: codeStrutStyle,
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<InlineSpan> _rowSpans(
    JsonTreeRow row,
    ThemeData theme,
    _RowStyles styles,
  ) {
    final base = codeTextStyle();

    TextSpan keyPrefix(JsonTreeNode node, String bracket) => TextSpan(
      children: [
        if (node.key != null) ...[
          TextSpan(text: jsonEncode(node.key!), style: styles.key),
          const TextSpan(text: ': '),
        ],
        TextSpan(text: bracket, style: base),
      ],
    );

    final node = row.node;
    if (row.isClose) {
      return [
        TextSpan(
          text: node.kind == JsonNodeKind.object ? '}' : ']',
          style: base,
        ),
      ];
    }
    if (!node.isContainer) {
      return [
        if (node.key != null) ...[
          TextSpan(text: jsonEncode(node.key!), style: styles.key),
          const TextSpan(text: ': '),
        ],
        TextSpan(text: _leafText(node), style: styles.leafFor(node.kind)),
      ];
    }
    if (!node.expandable) {
      return [keyPrefix(node, node.kind == JsonNodeKind.object ? '{}' : '[]')];
    }
    if (!controller.isExpanded(node)) {
      return [
        keyPrefix(node, node.kind == JsonNodeKind.object ? '{…}' : '[…]'),
        TextSpan(text: ' ×${node.children.length}', style: styles.muted),
      ];
    }
    return [
      keyPrefix(node, node.kind == JsonNodeKind.object ? '{' : '['),
    ];
  }

  String _leafText(JsonTreeNode node) => switch (node.kind) {
    JsonNodeKind.string => jsonEncode(node.value as String),
    JsonNodeKind.number => '${node.value}',
    JsonNodeKind.boolean => '${node.value}',
    JsonNodeKind.nullValue => 'null',
    _ => '',
  };
}

/// Token styles for one theme, computed once per list build instead of per
/// row build (rows rebuild on every scroll frame).
class _RowStyles {
  final TextStyle key;
  final TextStyle string;
  final TextStyle number;
  final TextStyle literal;
  final TextStyle muted;

  _RowStyles(ThemeData theme)
    : key = _merged(theme, 'attr'),
      string = _merged(theme, 'string'),
      number = _merged(theme, 'number'),
      literal = _merged(theme, 'literal'),
      muted = codeTextStyle().copyWith(color: theme.colorScheme.outline);

  static TextStyle _merged(ThemeData theme, String scope) =>
      codeTextStyle().merge(highlightTokenStyle(scope, theme.brightness));

  TextStyle leafFor(JsonNodeKind kind) => switch (kind) {
    JsonNodeKind.string => string,
    JsonNodeKind.number => number,
    JsonNodeKind.boolean => literal,
    JsonNodeKind.nullValue => literal,
    _ => string,
  };
}
