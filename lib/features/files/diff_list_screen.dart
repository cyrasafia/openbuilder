import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app_state.dart';
import '../../core/net/net_error.dart';
import '../../data/api/opencode_client.dart';
import '../../domain/models.dart';
import '../../ui/l10n_ext.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'diff_widgets.dart';

class DiffListScreen extends StatefulWidget {
  final String sessionId;
  final String? directory;
  const DiffListScreen({super.key, required this.sessionId, this.directory});

  @override
  State<DiffListScreen> createState() => _DiffListScreenState();
}

class _DiffListScreenState extends State<DiffListScreen> {
  List<FileDiff> _diffs = [];
  bool _loading = true;
  Object? _error;
  DiffMode _mode = DiffMode.uncommitted;
  String? _messageID;
  int _loadGen = 0;

  List<FileDiff>? _measuredFor;
  TextScaler? _measuredScaler;
  double _addW = 0;
  double _delW = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<String?> _lastUserMessageId(OpencodeClient c) async {
    String? before;
    const maxPages = 10;
    for (var p = 0; p < maxPages; p++) {
      final page = await c.messagesPage(
        widget.sessionId,
        limit: 100,
        before: before,
      );
      for (var i = page.entries.length - 1; i >= 0; i--) {
        if (page.entries[i].info.role == 'user') {
          return page.entries[i].info.id;
        }
      }
      if (page.nextCursor == null) return null;
      before = page.nextCursor;
    }
    return null;
  }

  Future<void> _load() async {
    final gen = ++_loadGen;
    final mode = _mode;
    final c = serverStore.client;
    if (c == null) {
      if (gen == _loadGen) {
        setState(() {
          _loading = false;
          _error = const KnownError(FriendlyErrorKind.notConnected);
        });
      }
      return;
    }
    setState(() {
      _loading = true;
      _diffs = [];
      _error = null;
    });
    try {
      String? messageID;
      if (mode == DiffMode.lastMessage) {
        messageID = await _lastUserMessageId(c);
      }
      if (gen != _loadGen) return;
      _messageID = messageID;
      if (mode == DiffMode.lastMessage && messageID == null) {
        _diffs = [];
        _error = const KnownError(FriendlyErrorKind.diffNoLastMessage);
      } else {
        final diffs = await c.diff(
          widget.sessionId,
          directory: widget.directory,
          mode: mode == DiffMode.branch ? 'branch' : 'git',
          messageID: messageID,
        );
        if (gen != _loadGen) return;
        _diffs = diffs;
        _error = null;
      }
    } catch (e) {
      if (gen == _loadGen) _error = e;
    } finally {
      if (mounted && gen == _loadGen) setState(() => _loading = false);
    }
  }

  void _onModeChanged(DiffMode mode) {
    if (mode == _mode) return;
    setState(() {
      _mode = mode;
      _messageID = null;
      _loading = true;
    });
    _load();
  }

  String _modeLabel(BuildContext context, DiffMode mode) {
    final loc = l(context);
    switch (mode) {
      case DiffMode.uncommitted:
        return loc.diffModeUncommitted;
      case DiffMode.branch:
        return loc.diffModeBranch;
      case DiffMode.lastMessage:
        return loc.diffModeLastMessage;
    }
  }

  int get _totalAdd => _diffs.fold(0, (s, d) => s + d.additions);
  int get _totalDel => _diffs.fold(0, (s, d) => s + d.deletions);

  /// Max digit count across all rows (incl. header totals) for each column,
  /// so the add column and del column line up vertically across rows.
  int get _addDigits => _diffs.fold(
        _totalAdd.toString().length,
        (m, d) => m > d.additions.toString().length
            ? m
            : d.additions.toString().length,
      );
  int get _delDigits => _diffs.fold(
        _totalDel.toString().length,
        (m, d) => m > d.deletions.toString().length
            ? m
            : d.deletions.toString().length,
      );

  double _measureColumnWidth(int digits, TextScaler scaler) {
    final tp = TextPainter(
      text: TextSpan(
        text: '+${'9' * digits}',
        style: const TextStyle(fontSize: 13).merge(DiffStat.statStyle),
      ),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    final w = tp.width;
    tp.dispose();
    return w;
  }

  bool get _canShowLastMessage {
    final conv = serverStore.conversationForRead(widget.sessionId);
    if (conv == null) return true;
    return conv.messages.any((m) => m.info.role == 'user');
  }

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    if (_diffs.isEmpty) {
      _measuredFor = null;
      _addW = 0;
      _delW = 0;
    } else if (!identical(_measuredFor, _diffs) || _measuredScaler != scaler) {
      _measuredFor = _diffs;
      _measuredScaler = scaler;
      _addW = _measureColumnWidth(_addDigits, scaler);
      _delW = _measureColumnWidth(_delDigits, scaler);
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Diff', style: TextStyle(fontSize: 16)),
        actions: [appBarActionsTrailing],
      ),
      body: Column(
        children: [
          _modeSelector(context),
          if (_diffs.isNotEmpty && !_loading && _error == null)
            _headerRow(context),
          Expanded(child: _body(context)),
        ],
      ),
    );
  }

  Widget _headerRow(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 6),
      child: Row(
        children: [
          Text(
            l(context).diffChangedFiles(_diffs.length),
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
          const Spacer(),
          DiffStat(
            add: _totalAdd,
            del: _totalDel,
            addWidth: _addW,
            delWidth: _delW,
          ),
        ],
      ),
    );
  }

  Widget _modeSelector(BuildContext context) {
    final modes = DiffMode.values
        .where((m) => m != DiffMode.lastMessage || _canShowLastMessage)
        .toList();
    final selected = modes.contains(_mode) ? _mode : DiffMode.uncommitted;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: SegmentedButton<DiffMode>(
        showSelectedIcon: false,
        selected: {selected},
        onSelectionChanged: (s) => _onModeChanged(s.first),
        segments: modes
            .map(
              (m) => ButtonSegment(
                value: m,
                label: Text(_modeLabel(context, m)),
              ),
            )
            .toList(),
      ),
    );
  }

  Widget _body(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              l(context).loadFailed,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              friendlyMessage(l(context), _error!),
              style: AppTheme.mono.copyWith(fontSize: 12),
            ),
            const SizedBox(height: 12),
            FilledButton(onPressed: _load, child: Text(l(context).retry)),
          ],
        ),
      );
    }
    if (_diffs.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.compare, size: 48, color: Colors.grey),
            const SizedBox(height: 12),
            Text(l(context).diffNoChanges),
          ],
        ),
      );
    }
    return ListView.separated(
      itemCount: _diffs.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final d = _diffs[i];
        final slash = d.file.lastIndexOf('/');
        final name = slash >= 0 ? d.file.substring(slash + 1) : d.file;
        final dir = slash >= 0 ? d.file.substring(0, slash) : '';
        return ListTile(
          leading: const Icon(Icons.description_outlined),
          title: Text(
            name,
            style: AppTheme.mono.copyWith(fontSize: 13),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: dir.isNotEmpty
              ? Text(
                  dir,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTheme.mono.copyWith(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.outline,
                  ),
                )
              : null,
          trailing: DiffStat(
            add: d.additions,
            del: d.deletions,
            addWidth: _addW,
            delWidth: _delW,
          ),
          onTap: () => context.push(
            '/session/${widget.sessionId}/diff/file'
            '?path=${Uri.encodeQueryComponent(d.file)}'
            '&directory=${Uri.encodeQueryComponent(widget.directory ?? '')}'
            '&mode=${_mode.name}'
            '${_messageID != null ? '&messageID=${Uri.encodeQueryComponent(_messageID!)}' : ''}',
          ),
        );
      },
    );
  }
}
