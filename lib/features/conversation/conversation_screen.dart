import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show
        BoxHitTestResult,
        BoxParentData,
        RenderAbstractViewport,
        RenderBox,
        RenderShiftedBox,
        RenderSliverMultiBoxAdaptor,
        ScrollCacheExtent,
        SliverMultiBoxAdaptorParentData;
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app_state.dart';
import '../../core/attachments/attachment_pipeline.dart';
import '../../core/attachments/file_ref.dart';
import '../../core/attachments/image_data_cache.dart';
import '../../core/net/net_error.dart';
import '../../core/logging/perf_probe.dart';
import '../../core/session/conversation_store.dart';
import '../../domain/models.dart';
import '../../core/session/file_browsing_store.dart';
import '../../ui/l10n_ext.dart';
import '../../l10n/gen/app_localizations.dart';
import '../files/file_browsing_container.dart';
import '../files/file_view_screen.dart';
import '../files/image_view.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import 'message_autolink.dart';

/// Max height of a footer card's scrollable content, as a fraction of the
/// screen height. Footer cards (todo / permission / question) bound their
/// scroll region with a [ConstrainedBox] using this factor; the card must NOT
/// rely on the footer's flex allocation, because a vertical [Column] gives its
/// non-flex children an unbounded main-axis constraint, which would defeat
/// [SingleChildScrollView].
const double _kFooterCardContentHeightFactor = 0.3;

const String _kCustomOptionValue = '\u0000custom';

/// 用户消息折叠门槛：自然高度超过「整屏高度 × 该比例」即可折叠（默认折叠，
/// 折叠后 clamp 到该高度）。用整屏高度（MediaQuery.size，键盘无关）而非列表
/// 视口高，保证门槛固定、不随键盘弹起/收起变化。
const double _kUserCollapseFraction = 0.4;

/// 折叠最小收益：自然高度超出门槛不足该值时不提供折叠（避免为几像素挂控件）。
const double _kUserCollapseMinGain = 24.0;

/// 用户消息外层垂直 padding（top/bottom 各 10）：自然高度按整条消息测量，
/// 壳层在气泡级 clamp，换算时扣掉这两段。
const double _kUserMsgVerticalPadding = 10.0;

/// 折叠/展开高度动画时长。
const Duration _kUserCollapseAnimDuration = Duration(milliseconds: 200);

/// 底部渐变遮罩高度（折叠/展开态共用）。气泡自身底 padding 12 + 展开留白
/// 44 = 56：展开态遮罩恰好铺满正文以下的空白区，指示不压正文。
const double _kUserCollapseFadeHeight = 56.0;

/// 展开态底部留白：气泡以同色同半径外壳向下延伸的空白区，承载渐变遮罩与
/// 收起指示。计入渲染高度，但自然高度口径不含该值（_noteUserHeight 测高时
/// 扣减），壳层动画目标显式加回——否则首末帧与动画中间帧高度不接续。
const double _kUserExpandBottomInset = 44.0;

class ConversationScreen extends StatefulWidget {
  final String sessionId;
  const ConversationScreen({super.key, required this.sessionId});

  @override
  State<ConversationScreen> createState() => _ConversationScreenState();
}

({
  Color text,
  Color outline,
  Color code,
  Color link,
  Color border,
  Color quoteBar,
  Color codeBackground,
})
_messagePalette(BuildContext context, bool user) {
  final theme = Theme.of(context);
  final a = theme.extension<AppColors>()!;
  if (user) {
    return (
      text: a.userText,
      outline: a.userOutline,
      code: a.userCode,
      link: a.userLink,
      border: a.userBorder,
      quoteBar: a.userQuoteBar,
      codeBackground: a.userCodeBackground,
    );
  }
  return (
    text: theme.colorScheme.onSurface,
    outline: theme.colorScheme.outline,
    code: a.code,
    link: a.link,
    border: a.border,
    quoteBar: a.quoteBar,
    codeBackground: a.codeBackground,
  );
}

MarkdownStyleSheet buildConversationMdStyle(BuildContext context,
    {required bool user}) {
  final p = _messagePalette(context, user);
  final mdBase = MarkdownStyleSheet.fromTheme(Theme.of(context));
  return mdBase.copyWith(
    p: TextStyle(fontSize: 14, height: 1.45, color: p.text),
    pPadding: const EdgeInsets.only(bottom: 6),
    strong: TextStyle(fontWeight: FontWeight.w600, color: p.text),
    h1: mdBase.h1?.copyWith(color: p.text, height: 1.45),
    h2: mdBase.h2?.copyWith(color: p.text, height: 1.45),
    h3: mdBase.h3?.copyWith(color: p.text, height: 1.45),
    h4: mdBase.h4?.copyWith(color: p.text, height: 1.45),
    h5: mdBase.h5?.copyWith(color: p.text, height: 1.45),
    h6: mdBase.h6?.copyWith(color: p.text, height: 1.45),
    em: mdBase.em?.copyWith(color: p.text),
    del: mdBase.del?.copyWith(color: p.text),
    tableHead: mdBase.tableHead?.copyWith(color: p.text),
    tableBody: mdBase.tableBody?.copyWith(color: p.text),
    tableBorder: TableBorder.all(color: p.border),
    tableColumnWidth: const IntrinsicColumnWidth(),
    tableScrollbarThumbVisibility: false,
    horizontalRuleDecoration: BoxDecoration(
      border: Border(top: BorderSide(color: p.border, width: 1)),
    ),
    a: TextStyle(color: p.link),
    code: TextStyle(fontSize: 13, fontFamily: 'monospace', color: p.code),
    codeblockDecoration: BoxDecoration(
      color: p.codeBackground,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: p.border),
    ),
    codeblockPadding: const EdgeInsets.all(12),
    listBullet: TextStyle(color: p.text),
    blockquote: TextStyle(color: p.text, fontStyle: FontStyle.italic),
    blockquoteDecoration: BoxDecoration(
      border: Border(left: BorderSide(color: p.quoteBar, width: 3)),
    ),
    blockquotePadding: const EdgeInsets.only(left: 12),
  );
}

sealed class _PendingItem {
  const _PendingItem();
}

final class _PendingAttachment extends _PendingItem {
  final AttachmentPreview preview;
  const _PendingAttachment(this.preview);
}

final class _PendingFileRef extends _PendingItem {
  final FileRef ref;
  const _PendingFileRef(this.ref);
}

class _ConversationScreenState extends State<ConversationScreen>
    with WidgetsBindingObserver {
  final _scrollController = ScrollController();
  final _ctl = TextEditingController();
  bool _cmdMode = false;
  bool _shellMode = false;
  final List<_PendingItem> _pending = [];
  bool _cmdRefreshTriggered = false;
  bool _didRestoreDraft = false;
  int _lastMsgCount = 0;
  bool _wasBusy = false;

  static const _kAutoScrollPixels = 50.0;
  static const _kPaginationScreens = 2.0;
  // 回顶/回底悬浮按钮共用同一显隐门槛：屏数 × 整屏高度（MediaQuery 屏高，
  // 不受键盘弹起影响）。用整屏高度而非实际列表视口高 _viewportHeight（键盘展开
  // 时变窄，会使门槛被低估、按钮凭空出现）；两者屏数也共用，保证一致的"距离感"。
  static const _kScrollButtonThresholdScreens = 2.0;
  static const _kKeepAliveWindow = 48;
  static const _kAutolinkCacheMax = 512;
  static const _kCacheExtentBase = 250.0;
  static const _kDriverStepScreens = 0.5;
  static const _kDriverMaxScreens = 8.0;
  static const _kDriverResetMaxScreens = 24.0;

  final _listKey = GlobalKey();
  final _backToTopTarget = ValueNotifier<double?>(null);
  final _farFromBottom = ValueNotifier<bool>(false);
  final _keepAliveIds = ValueNotifier<Set<String>>(const {});
  final _messageChildCache = <String, Widget>{};
  final _autolinkCache = <String, String>{};
  final _partWidgetCache = _PartWidgetCache();
  int? _lastMsgVersion;
  bool? _lastShowThinking;

  final _sizeKeys = <String, GlobalKey>{};
  final _heightCache = <String, double>{};

  // 用户消息折叠：自然（展开）高度按 id 记录，与 _heightCache 分离——折叠渲染
  // 时 _heightCache 存 clamp 后高度（滚动几何用），自然高度另行保存供判定。
  final _userNaturalHeight = <String, double>{};
  final _expandedUserIds = <String>{};
  // 展开动画进行中的消息 id：动画中间高度不是自然高度，测高回调须忽略。
  final _userAnimatingIds = <String>{};
  bool _collapseRebuildScheduled = false;

  final _sliverKey = GlobalKey();
  final _footerSizeKey = GlobalKey();
  double _footerRowHeight = 0;
  double _viewportHeight = 0;
  // 整屏高度（MediaQuery 屏高，键盘无关），作为悬浮按钮门槛的"一屏"参考。
  double _screenHeight = 0;
  double? _widthBaseline;
  TextScaler? _textScaleBaseline;

  final _keepAliveLru = <String>{};
  bool _keepAliveLruDirty = false;
  bool _frameEvalScheduled = false;

  double _cacheExtent = _kCacheExtentBase;
  bool _driverActive = false;
  bool _driverResetMode = false;

  /// Transition gate: false during the push transition animation, true after.
  /// Heavy body content (message list, bottom bar) is deferred until the
  /// animation completes so the ~300ms transition frames don't compete with
  /// reconcile decode + message layout.
  final _transitionDone = ValueNotifier<bool>(false);
  Animation<double>? _routeAnimation;
  bool _didEnterSync = false;
  bool _enterSyncInFlight = false;
  bool _enterSyncDirty = false;

  /// 距底基底 = 8(留白 sliver) + footer 动态行高 + 8(消息 SliverPadding 底侧)。
  double get _footerHeight => 16 + _footerRowHeight;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scrollController.addListener(_onScroll);
    serverStore.commandsNotifier.addListener(_onCommandsChanged);
    serverStore.addListener(_onServerStoreChanged);
    final conv = serverStore.conversationFor(widget.sessionId);
    if (conv != null) {
      conv.addListener(_onDraftChange);
      _tryRestoreDraft(conv, allowSetState: false); // 首帧 build 前，仅写字段
    }
    PerfProbe.I.beginWindow('enter-session:${widget.sessionId}');
    if (PerfProbe.I.isStarted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // 转场动画约 300ms；在 ~1.2s 后收尾窗口，覆盖入场 + 首批加载/SSE。
        Future.delayed(const Duration(milliseconds: 1200), () {
          if (mounted) PerfProbe.I.endWindow('enter-session:${widget.sessionId}');
        });
      });
    }
  }

  void _onServerStoreChanged() {
    if (!mounted || !_transitionDone.value) return;
    final conv = serverStore.conversationForRead(widget.sessionId);
    if (conv == null) return;
    if (!conv.gated && !conv.reconciling && serverStore.isSessionStale(widget.sessionId)) {
      if (_enterSyncInFlight) {
        _enterSyncDirty = true;
        return;
      }
      _didEnterSync = false;
      _triggerEnterSync();
    }
  }

  @override
  void didChangeMetrics() {
    // 键盘/旋转/分屏：视口几何变化不一定伴随滚动事件，主动触发帧评估
    // （宽度变化在评估内比对基线并清空高度缓存）。
    _scheduleFrameEval();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _installTransitionGate();
    _mdStyleUser = _buildMdStyle(user: true);
    _mdStyleAssistant = _buildMdStyle(user: false);
    // Cached message widgets freeze build-time values (theme/locale/textScaler);
    // an inherited change must invalidate them so they rebuild with new styles.
    _messageChildCache.clear();
    _partWidgetCache.clear();
  }

  void _installTransitionGate() {
    if (!mounted || _transitionDone.value || _routeAnimation != null) return;
    final anim = ModalRoute.of(context)?.animation;
    if (anim == null || anim.status == AnimationStatus.completed) {
      _transitionDone.value = true;
      _triggerEnterSync();
      return;
    }
    _routeAnimation = anim;
    anim.addStatusListener(_onRouteAnimationStatus);
    if (anim.status == AnimationStatus.completed) {
      _onRouteAnimationStatus(AnimationStatus.completed);
    }
  }

  void _onRouteAnimationStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    _routeAnimation?.removeStatusListener(_onRouteAnimationStatus);
    _routeAnimation = null;
    _transitionDone.value = true;
    _triggerEnterSync();
  }

  Future<void> _triggerEnterSync() async {
    if (_didEnterSync || _enterSyncInFlight) return;
    _didEnterSync = true;
    _enterSyncInFlight = true;
    PerfProbe.I.markEvent('conv-build enter-sync ${widget.sessionId}');
    try {
      final conv0 = serverStore.conversationForRead(widget.sessionId);
      if (conv0?.reconciling ?? false) {
        await serverStore.awaitReconcile(widget.sessionId);
      }
      if (!mounted) return;
      final stale = await serverStore.ensureSessionFresh(widget.sessionId);
      final conv = mounted ? serverStore.conversationForRead(widget.sessionId) : null;
      if (conv == null) return;
      if (!stale) {
        if (conv.gated && !conv.reconciling) {
          unawaited(serverStore.reconcileConversation(widget.sessionId));
        }
        return;
      }
      conv.beginGate();
      unawaited(serverStore.reconcileConversation(widget.sessionId));
    } finally {
      _enterSyncInFlight = false;
      if (_enterSyncDirty && mounted) {
        _enterSyncDirty = false;
        // 仅当仍"可行动"才重跑：门控已开（本轮已处理）/正在对账 / 已非 stale
        // 都无需再跑——否则本轮 ensureSessionFresh 自身的尾部 notify 会把
        // dirty 置位，导致每次 stale 进页多跑一轮单查+对账。
        final c = serverStore.conversationForRead(widget.sessionId);
        if (c != null &&
            !c.gated &&
            !c.reconciling &&
            serverStore.isSessionStale(widget.sessionId)) {
          _didEnterSync = false;
          _triggerEnterSync();
        }
      }
    }
  }

  @override
  void dispose() {
    _routeAnimation?.removeStatusListener(_onRouteAnimationStatus);
    final conv = serverStore.conversationForRead(widget.sessionId);
    if (conv != null) {
      conv.removeListener(_onDraftChange);
      conv.setDraft(_ctl.text, shell: _shellMode);
      conv.persistDraft(); // unawaited，尽力而为（硬杀靠 pause flush 兜底）
    }
    serverStore.commandsNotifier.removeListener(_onCommandsChanged);
    serverStore.removeListener(_onServerStoreChanged);
    serverStore.fileBrowsing.unregisterRefPicker(widget.sessionId);
    serverStore.setActiveConversation(null);
    WidgetsBinding.instance.removeObserver(this);
    _scrollController.dispose();
    _backToTopTarget.dispose();
    _farFromBottom.dispose();
    _keepAliveIds.dispose();
    _transitionDone.dispose();
    _ctl.dispose();
    super.dispose();
  }

  void _onCommandsChanged() {
    if (mounted && _cmdMode) setState(() {});
  }

  /// Reactive 恢复：conv notifyListeners（含 loadDraftOnly 完成）后触发。
  void _onDraftChange() {
    final c = serverStore.conversationForRead(widget.sessionId);
    if (c != null) _tryRestoreDraft(c); // 默认 allowSetState=true（已脱离 build）
  }

  /// 把 store 内存草稿恢复到输入框。`allowSetState` 控制是否可 setState：
  /// 从 build/initState 首帧前调用传 false（仅写字段）；从 listener 调用默认 true。
  void _tryRestoreDraft(ConversationStore c, {bool allowSetState = true}) {
    if (_didRestoreDraft || !c.draftLoaded) return;
    _didRestoreDraft = true;
    if (_ctl.text.isEmpty && c.draftText.isNotEmpty) {
      final cmdMode =
          !c.draftShell &&
          c.draftText.startsWith('/') &&
          !c.draftText.contains(' '); // CD-22：排除 shell 模式，避免误显 / 命令面板
      _ctl.text = c.draftText;
      _shellMode = c.draftShell;
      _cmdMode = cmdMode;
      if (cmdMode && (!_cmdRefreshTriggered || serverStore.commandsDegraded)) {
        _cmdRefreshTriggered = true;
        _triggerCommandRefresh();
      }
      if (allowSetState && mounted) setState(() {});
    }
  }

  bool _hasDynamicFooterRow(ConversationStore conv) =>
      (conv.isRetry &&
          conv.retryMessage != null &&
          conv.retryMessage!.isNotEmpty) ||
      conv.busy ||
      conv.loading;

  void _onScroll() {
    _updateFarFromBottom();
    _maybeLoadEarlier();
    _scheduleFrameEval();
  }

  void _scheduleFrameEval() {
    if (_frameEvalScheduled) return;
    _frameEvalScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _frameEvalScheduled = false;
      if (!mounted) return;
      if (_keepAliveLruDirty) {
        _keepAliveLruDirty = false;
        final next = Set<String>.of(_keepAliveLru);
        final cur = _keepAliveIds.value;
        if (next.length != cur.length || !next.containsAll(cur)) {
          _keepAliveIds.value = next;
        }
      }
      _evaluateFrame();
    });
  }

  /// itemBuilder 运行在 buildScope 内，这里只做记录；集合更新与通知批处理
  /// 到帧后（build 期间通知会让已挂载的 _KeepAliveMessage markNeedsBuild 抛异常）。
  void _noteMessageBuilt(String id) {
    final isNew = !_keepAliveLru.contains(id);
    _keepAliveLru.remove(id);
    _keepAliveLru.add(id);
    var evicted = false;
    while (_keepAliveLru.length > _kKeepAliveWindow) {
      _keepAliveLru.remove(_keepAliveLru.first);
      evicted = true;
    }
    if (isNew || evicted) _keepAliveLruDirty = true;
  }

  /// 找 render object 所属 sliver 直接子级的 parentData（中间隔着
  /// RepaintBoundary 等 proxy，需向上走）。在 keep-alive 桶中的条目返回
  /// keptAlive=true（其 rect 是过期布局位置，不可信）。
  SliverMultiBoxAdaptorParentData? _sliverParentDataOf(RenderObject rb) {
    RenderObject? node = rb;
    while (node != null) {
      final pd = node.parentData;
      if (pd is SliverMultiBoxAdaptorParentData) return pd;
      node = node.parent;
    }
    return null;
  }

  void _evaluateFrame() {
    _evaluateFrameImpl();
  }

  void _evaluateFrameImpl() {
    final conv = serverStore.conversationForRead(widget.sessionId);
    if (conv == null) return;
    final msgs = conv.renderableMessages;
    final msgCount = msgs.length;

    final mqSize = MediaQuery.sizeOf(context);
    final w = mqSize.width;
    _screenHeight = mqSize.height;
    final ts = MediaQuery.textScalerOf(context);
    if (_widthBaseline == null) {
      _widthBaseline = w;
      _textScaleBaseline = ts;
    } else if (w != _widthBaseline || ts != _textScaleBaseline) {
      _widthBaseline = w;
      _textScaleBaseline = ts;
      _heightCache.clear();
      _userNaturalHeight.clear(); // 文本重排使自然高度全部失效，重测后再判定
      // 折叠态 host 的渲染尺寸是固定 clamp 高，不会自发产生尺寸变化通知；
      // 主动重建一次让 host 拿到 naturalHeight=null 透传，尺寸变化走既有
      // 通知路径重判（否则收窄重排后不再超门槛的消息会残留折叠壳）。
      _scheduleCollapseRebuild();
      _driverResetMode = true;
      _driverAbortedRunTop = null; // 基线变化使先前中止失效，重置上限生效
    }

    final listBox = _listKey.currentContext?.findRenderObject();
    if (listBox is! RenderBox || !listBox.attached || !listBox.hasSize) {
      _setBackToTopTarget(null);
      return;
    }
    final h = listBox.size.height;
    _viewportHeight = h;
    _updateFarFromBottom();
    if (msgCount == 0 || !_scrollController.hasClients || h <= 0) {
      _setBackToTopTarget(null);
      _stopDriver();
      return;
    }
    final pixels = _scrollController.position.pixels;

    // 锚定最顶挂载消息（sliver 的 lastChild）：其绝对 scroll 位置从渲染树读
    // （layout pass 已积分全部当前高度），故吸收了底部一切变化（含不可观测的
    // 流式增长），不受底部 _heightCache 缺口影响。runTop/visLowIdx 皆相对此
    // 锚做算术，只用新鲜高度（挂载区 + 更早的稳定消息）；最底陈旧的流式 run
    // 根本不进场。
    final sliverRO = _sliverKey.currentContext?.findRenderObject();
    RenderBox? lastChild;
    var lastIdx = -1;
    if (sliverRO is RenderSliverMultiBoxAdaptor) {
      lastChild = sliverRO.lastChild;
      final pd = lastChild?.parentData;
      if (pd is SliverMultiBoxAdaptorParentData) lastIdx = pd.index ?? -1;
    }
    if (lastChild == null || lastIdx < 0 || lastIdx >= msgCount) {
      _setBackToTopTarget(null);
      _stopDriver();
      _maybeLoadEarlier();
      return;
    }
    // lastChild 的 trailing scroll 边（reverse 下即其顶边）。screen 坐标换算：
    // scroll 偏移 s 的内容点 screenY = vpBottom - (s - pixels)，故 s = pixels +
    // vpBottom - screenY。
    final vpBottom = listBox.localToGlobal(Offset.zero).dy + h;
    final lastTop = pixels + vpBottom - lastChild.localToGlobal(Offset.zero).dy;

    // Seed heights for ALL mounted sliver children directly from their render
    // objects. _heightCache otherwise lags because _measuredMessage's
    // measurement callback is registered during build (after _scheduleFrameEval
    // registers _evaluateFrame), so FIFO runs _evaluateFrame first.
    //
    // 原 seed 只覆盖 lastChild：reconcile 一次性挂上多条新消息时，可见区里
    // lastChild 之外的中间消息没被 seed，walk-down 第一步就 break（visLowIdx=-1）
    // → _stopDriver 把 cacheExtent 收回 base → 刚挂上的 child 被 unmount →
    // 下一帧 gap 又成立 → driver 再扩。这个 expand/stop 振荡要 ~1s 才收敛，
    // 期间还触发 _measuredMessage 回调读未布局 child 的 .size 爆异常洪流。
    // 遍历整条已挂载链一次性补齐高度，单帧闭合缺口，driver 不再反复横跳。
    if (sliverRO is RenderSliverMultiBoxAdaptor) {
      var child = sliverRO.firstChild;
      while (child != null) {
        if (child.hasSize) {
          final pd = child.parentData;
          if (pd is SliverMultiBoxAdaptorParentData) {
            final idx = pd.index ?? -1;
            if (idx >= 0 && idx < msgCount) {
              final ch = child.size.height;
              if (ch > 0) {
                final cid = msgs[idx].id;
                if (_heightCache[cid] != ch) _heightCache[cid] = ch;
              }
            }
          }
        }
        child = sliverRO.childAfter(child);
      }
    }

    const eps = 1.0;
    double? target;
    final viewBottom = pixels < _footerHeight ? _footerHeight : pixels;
    // 从 lastChild 向下走，定位覆盖 viewBottom 的视口下缘消息。
    var visLowIdx = -1;
    var topEdge = lastTop; // 当前消息的 trailing（顶）边
    for (var i = lastIdx; i >= 0; i--) {
      final mi = _heightCache[msgs[i].id];
      if (mi == null || mi <= 0) break; // 缺口，无法定位
      if (viewBottom < topEdge + eps && viewBottom >= topEdge - mi - eps) {
        visLowIdx = i;
        break;
      }
      topEdge -= mi;
    }
    if (visLowIdx >= 0) {
      // run = 一轮：user 消息 + 其后全部 assistant 回复（newest-first 下回复在
      // 更小 index）。run 顶锚定该 user 消息；无归属 user 的连续 assistant
      // （列表头/用户消息仍在上一页）沿用旧语义自成一 run。
      var lo = visLowIdx;
      var hi = visLowIdx;
      if (!msgs[hi].isUser) {
        while (hi < msgCount - 1 && !msgs[hi + 1].isUser) {
          hi++;
        }
        if (hi < msgCount - 1) hi++;
      }
      while (lo > 0 && !msgs[lo - 1].isUser) {
        lo--;
      }
      // runTop = child hi 的 trailing 边，相对 lastTop 锚。
      var gap = false;
      var runTop = lastTop;
      if (hi >= lastIdx) {
        for (var i = lastIdx; i < hi; i++) {
          final mi = _heightCache[msgs[i + 1].id];
          if (mi == null || mi <= 0) {
            gap = true;
            break;
          }
          runTop += mi;
        }
      } else {
        for (var i = lastIdx; i > hi; i--) {
          final mi = _heightCache[msgs[i].id];
          if (mi == null || mi <= 0) {
            gap = true;
            break;
          }
          runTop -= mi;
        }
      }
      // run 自身跨度（≥2 屏门槛）。
      var span = 0.0;
      for (var i = lo; i <= hi; i++) {
        final mi = _heightCache[msgs[i].id];
        if (mi == null || mi <= 0) {
          gap = true;
          break;
        }
        span += mi;
      }
      // 占满：run 顶到视口上缘（run 底 ≤ pixels 由 visLowIdx 在 run 内自动成立）。
      final occupied = runTop >= pixels + h - eps;
      if (occupied) {
        if (!gap) {
          _driverAbortedRunTop = null;
          // 跨度门槛取 _kScrollButtonThresholdScreens × _screenHeight（整屏高度，
          // 不受键盘弹起影响），而非实际视口高 h：键盘展开时视口变窄，2*h 会被
          // 低估使按钮凭空出现。点击目标 target 仍用实际 h 以对齐当前视口顶。
          if (span >= _kScrollButtonThresholdScreens * _screenHeight) {
            target = runTop - h;
          }
        }
        _drivePreAssembly(conv, gap: gap, runTopId: msgs[hi].id);
      } else {
        _stopDriver();
      }
    } else {
      _stopDriver();
    }
    _setBackToTopTarget(target);
    _maybeLoadEarlier();
  }

  /// 预组装 driver：占满单一 run 且求和范围有缺口时，逐帧扩大 cacheExtent
  /// 补测；缺口闭合后的下一帧评估走 _stopDriver 收回。触发只做"占满 + 缺口
  /// + 非 busy"宽松判定——跨度/滚出下界在下方缺口场景会低估死锁（只约束按钮
  /// 显隐，不约束补测）。
  void _drivePreAssembly(
    ConversationStore conv, {
    required bool gap,
    required String runTopId,
  }) {
    final h = _viewportHeight;
    if (!gap || conv.busy || h <= 0) {
      if (_driverActive) _stopDriver();
      return;
    }
    if (_driverAbortedRunTop == runTopId) return;
    final maxExtent =
        (_driverResetMode ? _kDriverResetMaxScreens : _kDriverMaxScreens) * h;
    if (_cacheExtent >= maxExtent) {
      _stopDriver();
      _driverAbortedRunTop = runTopId;
      return;
    }
    final next = math.min(
      (_driverActive ? _cacheExtent : _kCacheExtentBase) +
          _kDriverStepScreens * h,
      maxExtent,
    );
    _driverActive = true;
    setState(() => _cacheExtent = next);
  }

  String? _driverAbortedRunTop;

  void _stopDriver() {
    _driverActive = false;
    _driverResetMode = false;
    if (_cacheExtent != _kCacheExtentBase) {
      setState(() => _cacheExtent = _kCacheExtentBase);
    }
  }

  void _setBackToTopTarget(double? target) {
    final cur = _backToTopTarget.value;
    // runTop - h 的浮点累加每帧可能产生 ulp 级抖动（实测 1e-13 量级在两值间
    // 反复横跳）。精确 != 会让 ValueNotifier 每帧通知一次，按钮被无谓 rebuild。
    // 半像素以内视为相等。
    final same =
        (cur == null && target == null) ||
        (cur != null && target != null && (cur - target).abs() < 0.5);
    if (!same) {
      _backToTopTarget.value = target;
    }
  }

  void _updateFarFromBottom() {
    if (_screenHeight <= 0 || !_scrollController.hasClients) return;
    final far =
        _scrollController.position.pixels >
        _kScrollButtonThresholdScreens * _screenHeight;
    if (_farFromBottom.value != far) _farFromBottom.value = far;
  }

  void _scrollToBottom() {
    unawaited(
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  /// target 为 run 上边缘距底偏移 - 视口高（reversed 坐标系 pixels）。
  void _scrollToRunTop(double target) {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    final t = target.clamp(pos.minScrollExtent, pos.maxScrollExtent);
    final screens = _viewportHeight > 0
        ? (t - pos.pixels).abs() / _viewportHeight
        : 1.0;
    final ms = (250 * screens).clamp(250.0, 500.0).round();
    unawaited(
      _scrollController.animateTo(
        t,
        duration: Duration(milliseconds: ms),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  void _maybeLoadEarlier() {
    final conv = serverStore.conversationForRead(widget.sessionId);
    if (conv == null) return;
    if (!conv.hasMore || conv.loadingEarlier) return;
    if (!_scrollController.hasClients || _viewportHeight <= 0) return;
    final pos = _scrollController.position;
    if (pos.pixels <
        pos.maxScrollExtent - _kPaginationScreens * _viewportHeight) {
      return;
    }
    conv.loadOnePage().then((madeProgress) {
      // IR-1: stop the chain on failure (no progress) to prevent request
      // storms when offline. The user can retry by scrolling away and back.
      if (!mounted || !madeProgress) return;
      // Chain: if the viewport isn't filled yet (still at top), keep loading.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _maybeLoadEarlier();
      });
    });
  }

  Widget _cachedMessage(DisplayMessage msg) {
    final id = msg.id;
    if (msg.isUser) {
      return _messageChildCache[id] ??= _userBubble(msg);
    }
    if (msg.type != 'assistant') {
      return _messageChildCache[id] ??= _noticeMessage(msg);
    }
    if (msg.finish == null) {
      _messageChildCache.remove(id);
      return _message(msg, stable: false);
    }
    return _messageChildCache[id] ??= _message(msg, stable: true);
  }

  String _syntheticLabel(String text) {
    if (text.startsWith('<shell')) {
      final cmd = RegExp(r'command="([^"]*)"').firstMatch(text)?.group(1);
      if (cmd != null && cmd.isNotEmpty) return '\$ $cmd';
    }
    return text;
  }

  String _subagentSyntheticLabel(DisplayMessage m) {
    final desc = m.description;
    if (desc != null && desc.trim().isNotEmpty) return desc.trim();
    final fromText =
        RegExp(r'description="([^"]*)"').firstMatch(m.text ?? '')?.group(1);
    if (fromText != null && fromText.trim().isNotEmpty) return fromText.trim();
    return 'subagent';
  }

  /// 统一系统提示样式（design-subagent-background §D5）：低强调行式，承载
  /// 后台任务启停 / 切换模型 / 切换 Agent / 系统与技能通知。
  Widget _noticeMessage(DisplayMessage m) {
    final scheme = Theme.of(context).colorScheme;
    final loc = l(context);
    final IconData icon;
    Color color = scheme.outline;
    final String label;
    VoidCallback? onTap;
    switch (m.type) {
      case 'synthetic' when m.metadata?['source'] == 'subagent':
        final childId = m.metadata?['childID']?.toString();
        final name = _subagentSyntheticLabel(m);
        switch (m.metadata?['state']?.toString()) {
          case 'completed':
            icon = Icons.check_circle_outline;
            label = loc.bgTaskCompleted(name);
          case 'failed':
          case 'error':
            icon = Icons.error_outline;
            color = const Color(0xFFF85149);
            label = loc.bgTaskFailed(name);
          case 'cancelled':
          case 'interrupted':
            icon = Icons.stop_circle_outlined;
            label = loc.bgTaskCancelled(name);
          default:
            icon = Icons.circle_outlined;
            label = loc.bgTaskDone;
        }
        if (childId != null && childId.isNotEmpty) {
          onTap = () => _showTaskDetail(childId, name);
        }
      case 'system' when m.metadata?['kind'] == 'background-started':
        final childId = m.metadata?['childID']?.toString();
        final name = (m.metadata?['label'] ?? m.description ?? '').toString();
        icon = Icons.rocket_launch_outlined;
        label = loc.bgTaskStarted(name);
        if (childId != null && childId.isNotEmpty) {
          onTap = () => _showTaskDetail(childId, name);
        }
      case 'model-switched':
        icon = Icons.swap_horiz;
        label = '${m.previousLabel ?? ''} → ${m.currentLabel ?? ''}';
      case 'agent-switched':
        icon = Icons.smart_toy_outlined;
        label = '${m.previousLabel ?? ''} → ${m.currentLabel ?? ''}';
      case 'shell':
        icon = Icons.terminal;
        label = '\$ ${m.shellCommand ?? ''}';
      case 'skill':
        icon = Icons.bolt_outlined;
        label = m.description ?? m.text ?? '';
      default:
        icon = Icons.info_outline;
        label = m.type == 'synthetic'
            ? _syntheticLabel(m.text ?? '')
            : (m.description ?? m.text ?? '');
    }
    if (label.trim().isEmpty) return const SizedBox.shrink();
    return Padding(
      key: ValueKey(m.id),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 15, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                    height: 1.45,
                  ),
                ),
              ),
              if (onTap != null) ...[
                const SizedBox(width: 4),
                Icon(Icons.chevron_right, size: 16, color: scheme.outline),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 用户气泡（无外层 Padding/Align——折叠壳挂在气泡级，裁剪宽度即气泡宽）。
  Widget _userBubble(DisplayMessage msg) {
    final id = msg.id;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _userBubbleColor(),
        borderRadius: BorderRadius.circular(14),
      ),
      constraints: const BoxConstraints(maxWidth: 320),
      // 正文 tap 被 selectable markdown 的内部手势赢走（光标/选区），壳层的
      // onTap 够不到文本区——改由 onTapText 在文本 tap 落点观察并切换折叠，
      // 链接 tap 由 link recognizer 赢出、不触发 onTapText，两者天然分流。
      // 守卫可折叠性：短消息无需切换；且首帧自然高度未测出时 tap 不得抢先
      // 标记 expanded（否则跨过门槛后不再默认折叠）。闭包在 tap 时读最新
      // 测量值，不受实例缓存影响。
      child: _parts(
        msg.parts,
        user: true,
        stable: true,
        onTextTap: () {
          final natural = _userNaturalHeight[id];
          if (natural == null || !_userCollapsibleHeight(natural)) return;
          _toggleUserExpanded(id);
        },
      ),
    );
  }

  Widget _measuredMessage(DisplayMessage msg) {
    final id = msg.id;
    final isUser = msg.isUser;
    _noteMessageBuilt(id);
    final key = _sizeKeys.putIfAbsent(id, () => GlobalKey());
    // SizeChangedLayoutNotifier 跳过首次布局（_oldSize==null），静态消息
    // 若无此补偿则永不入 _heightCache。
    if (!_heightCache.containsKey(id)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // Element.size 内部调 RenderBox.size，未 layout 会 throw（不是返回
        // null）。reconcile + driver 扩 cacheExtent 时，sliver 把新 child 挂上
        // 树但本轮 layout 不一定走到（cacheExtent 边界 child），直接读 .size
        // 会爆 "Bad state: RenderBox was not laid out"。手动 findRenderObject
        // + hasSize 守卫跳过未布局的 child，下一帧会再尝试。
        final ro = key.currentContext?.findRenderObject();
        if (ro is! RenderBox || !ro.hasSize) return;
        final h = ro.size.height;
        if (h <= 0) return;
        // 评估帧的 seed 循环可能已先写入同值高度——缓存写入跳过，但用户消息
        // 的折叠判定仍需该高度（seed 路径不做折叠判定）。
        if (_heightCache[id] != h) {
          _heightCache[id] = h;
          _scheduleFrameEval();
        }
        if (isUser) _noteUserHeight(id, h);
      });
    }
    return NotificationListener<SizeChangedLayoutNotification>(
      onNotification: (_) {
        // 通知在本 render object 自己的 performLayout 内派发——此时它是
        // dirty 的，Element.size 的 debug 断言会抛"marked dirty for layout"。
        // 直接读 RenderBox.size（performLayout 内允许，尺寸此刻已定）。
        final ro = key.currentContext?.findRenderObject();
        if (ro is! RenderBox || !ro.hasSize) return false;
        final h = ro.size.height;
        if (h > 0 && _heightCache[id] != h) {
          _heightCache[id] = h;
          if (isUser) _noteUserHeight(id, h);
          _scheduleFrameEval();
        }
        return false;
      },
      child: SizeChangedLayoutNotifier(
        key: key,
        // Finished messages have stable content → cache the widget instance so
        // identity short-circuit prunes the whole subtree on non-content
        // rebuilds (streaming per-token, driver steps, busy/showThinking).
        // RepaintBoundary: isolate each message's paint layer so streaming
        // text repaints don't recomposite the entire scroll viewport.
        child: RepaintBoundary(
          child: _KeepAliveMessage(
            key: ValueKey(id),
            msgId: id,
            keepAliveIds: _keepAliveIds,
            // 折叠壳在实例缓存之外：展开/收起只重建壳，缓存的内容子树走等值剪枝。
            child: isUser ? _userCollapseHost(msg) : _cachedMessage(msg),
          ),
        ),
      ),
    );
  }

  Widget _userCollapseHost(DisplayMessage msg) {
    final id = msg.id;
    return Padding(
      key: ValueKey(id),
      padding: const EdgeInsets.only(
        left: 40,
        top: _kUserMsgVerticalPadding,
        bottom: _kUserMsgVerticalPadding,
      ),
      child: Align(
        alignment: Alignment.centerRight,
        child: _UserCollapseHost(
          key: ValueKey('uc:$id'),
          naturalHeight: _userNaturalHeight[id],
          expanded: _expandedUserIds.contains(id),
          onToggle: () => _toggleUserExpanded(id),
          onAnimating: (animating) => _setUserAnimating(id, animating),
          child: _cachedMessage(msg),
        ),
      ),
    );
  }

  /// 折叠 clamp 高度 = 整屏高（MediaQuery.size，键盘无关）× 比例。屏幕旋转/
  /// 分屏才变；键盘弹起只改 viewInsets 不改 size，故门槛固定。
  double get _userCollapseMaxHeight =>
      MediaQuery.sizeOf(context).height * _kUserCollapseFraction;

  bool _userCollapsibleHeight(double natural) =>
      natural > _userCollapseMaxHeight + _kUserCollapseMinGain;

  /// 用户消息测高回调（事件驱动：首次布局补偿 / 尺寸变化通知，非每帧）。
  /// 折叠渲染时测得的是 clamp 高度，不更新自然高度；展开渲染时测得的即自然
  /// 高度，跨过折叠门槛时调度一次重建切入默认折叠。展开动画期间的中间高度
  /// 既非自然高也非 clamp 高，一并忽略（否则阈值振荡会打断动画）。
  /// 展开渲染含底部留白：按口径扣减后记录（自然高度统一不含留白）；仅在
  /// 「确为展开分支渲染」时扣减——naturalHeight 为空/不可折叠时走透传分支，
  /// 渲染高度本就不含留白。
  void _noteUserHeight(String id, double h) {
    if (!mounted) return;
    if (_userCollapsedRender(id)) return;
    if (_userAnimatingIds.contains(id)) return;
    final natural = _userNaturalHeight[id];
    final expandedRender = _expandedUserIds.contains(id) &&
        natural != null &&
        _userCollapsibleHeight(natural);
    final basis = expandedRender ? h - _kUserExpandBottomInset : h;
    if (natural == basis) return;
    final wasCollapsible = natural != null && _userCollapsibleHeight(natural);
    _userNaturalHeight[id] = basis;
    final isCollapsible = _userCollapsibleHeight(basis);
    if (wasCollapsible != isCollapsible) _scheduleCollapseRebuild();
  }

  bool _userCollapsedRender(String id) {
    final natural = _userNaturalHeight[id];
    if (natural == null) return false;
    if (!_userCollapsibleHeight(natural)) return false;
    return !_expandedUserIds.contains(id);
  }

  void _scheduleCollapseRebuild() {
    if (_collapseRebuildScheduled) return;
    _collapseRebuildScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _collapseRebuildScheduled = false;
      if (mounted) setState(() {});
    });
  }

  void _toggleUserExpanded(String id) {
    setState(() {
      if (_expandedUserIds.contains(id)) {
        _expandedUserIds.remove(id);
      } else {
        _expandedUserIds.add(id);
      }
    });
  }

  /// 折叠壳动画启停回调（无 setState：仅作测高回调的守卫标记，不影响渲染）。
  void _setUserAnimating(String id, bool animating) {
    if (animating) {
      _userAnimatingIds.add(id);
    } else {
      _userAnimatingIds.remove(id);
    }
  }

  Widget _footerRow(ConversationStore conv) {
    final Widget child;
    if (conv.workspaceMissing) {
      child = const _WorkspaceMissingBanner();
    } else if (conv.gated) {
      child = const _SyncingRow();
    } else if (conv.isRetry &&
        conv.retryMessage != null &&
        conv.retryMessage!.isNotEmpty) {
      child = _RetryMessage(message: conv.retryMessage!);
    } else if (_hasDynamicFooterRow(conv)) {
      child = const _TypingDots();
    } else {
      child = const SizedBox.shrink();
    }
    return NotificationListener<SizeChangedLayoutNotification>(
      onNotification: (_) {
        // 同 _measuredMessage：通知在本对象自己的 performLayout 内派发，
        // Element.size 的 dirty 断言会抛；直读 RenderBox.size。
        final ro = _footerSizeKey.currentContext?.findRenderObject();
        final h = (ro is RenderBox && ro.hasSize) ? ro.size.height : 0.0;
        if (h != _footerRowHeight) {
          _footerRowHeight = h;
          _scheduleFrameEval();
        }
        return false;
      },
      child: SizeChangedLayoutNotifier(
        key: _footerSizeKey,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: child,
        ),
      ),
    );
  }

  Widget _headerRow(ConversationStore conv) {
    final Widget child;
    if (conv.loadingEarlier) {
      child = const _LoadingEarlierRow();
    } else if (conv.loadEarlierError && conv.hasMore) {
      child = _LoadEarlierErrorRow(onRetry: _maybeLoadEarlier);
    } else {
      child = const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: child,
    );
  }

  /// busy 结束：流式离屏期间长高的末 run 成员高度不可观测，驱逐未挂载成员
  /// 的缓存项（按未测对待，由 driver 补测定终值）；已挂载成员的高度变化由
  /// SizeChangedLayoutNotification 自动更新。注意 keep-alive 桶中的条目仍
  /// 挂载但不参与 layout（高度是流式前的旧值），同样按未测驱逐。
  void _onBusyEnd(List<DisplayMessage> msgs) {
    for (final m in msgs) {
      final isUser = m.isUser;
      final id = m.id;
      final rb = _sizeKeys[id]?.currentContext?.findRenderObject();
      final laidOut =
          rb is RenderObject && !(_sliverParentDataOf(rb)?.keptAlive ?? true);
      if (!laidOut) {
        _heightCache.remove(id);
      }
      if (isUser) break;
    }
  }

  void _pruneMessageCaches(List<DisplayMessage> msgs) {
    final ids = <String>{for (final m in msgs) m.id};
    _sizeKeys.removeWhere((id, _) => !ids.contains(id));
    _heightCache.removeWhere((id, _) => !ids.contains(id));
    _messageChildCache.removeWhere((id, _) => !ids.contains(id));
    _userNaturalHeight.removeWhere((id, _) => !ids.contains(id));
    _expandedUserIds.removeWhere((id) => !ids.contains(id));
    _userAnimatingIds.removeWhere((id) => !ids.contains(id));
    _keepAliveLru.removeWhere((id) => !ids.contains(id));
    if (_driverAbortedRunTop != null && !ids.contains(_driverAbortedRunTop)) {
      _driverAbortedRunTop = null;
    }
  }

  void _openFiles(BuildContext context, String directory) {
    final store = serverStore.fileBrowsing;
    store.resetCollapse();
    store.registerRefPicker(widget.sessionId, (ref) {
      if (mounted) setState(() => _pending.add(_PendingFileRef(ref)));
    });
    final dir = Uri.encodeQueryComponent(directory);
    final snap = store.snapshotFor(widget.sessionId, directory);
    context.push(
      '/session/${widget.sessionId}/files?directory=$dir',
      extra: snap,
    );
  }

  @override
  Widget build(BuildContext context) {
    serverStore.setActiveConversation(widget.sessionId);
    final session = serverStore.sessionById(widget.sessionId);
    final conv = serverStore.conversationFor(widget.sessionId);
    if (conv == null) {
      return Scaffold(
        appBar: AppBar(),
        body: Center(child: Text(l(context).convUnavailable)),
      );
    }
    final directory = session?.directory ?? '';
    return Scaffold(
      // Keyboard avoidance is done by _KeyboardAvoider (viewInsets padding)
      // instead of resizeToAvoidBottomInset, so the Scaffold does not register
      // a viewInsets dependency and rebuild every keyboard-animation frame.
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        title: ListenableBuilder(
          listenable: serverStore,
          builder: (context, _) {
            final s = serverStore.sessionById(widget.sessionId);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  s?.title ?? l(context).convDefaultTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 16),
                ),
                if (s != null)
                  Builder(
                    builder: (context) {
                      final project = serverStore.projectDisplayOf(s);
                      final wt = serverStore.worktreeDisplayOf(s);
                      return Text(
                        wt.isEmpty ? project : '$project › $wt',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(context).colorScheme.outline,
                        ),
                      );
                    },
                  ),
              ],
            );
          },
        ),
        actions: [
          ListenableBuilder(
            listenable: serverStore,
            builder: (context, _) => Padding(
              padding: const EdgeInsets.only(right: 10),
              child: SseStatusDot(
                connected: serverStore.sseConnected,
                reconnecting: serverStore.sseReconnecting,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.folder_outlined),
            tooltip: l(context).fileTitle,
            onPressed: () => _openFiles(context, directory),
          ),
          ListenableBuilder(
            listenable: serverStore,
            builder: (context, _) {
              final s = serverStore.sessionById(widget.sessionId);
              final canDiff =
                  s != null &&
                  (serverStore.projectOf(s.projectID)?.workspaceCapable ??
                      false);
              if (!canDiff) return const SizedBox.shrink();
              return IconButton(
                icon: const Icon(Icons.compare),
                tooltip: 'Diff',
                onPressed: () => context.push(
                  '/session/${widget.sessionId}/diff'
                  '?directory=${Uri.encodeQueryComponent(directory)}',
                ),
              );
            },
          ),
          _MoreMenu(
            sessionId: widget.sessionId,
            directory: directory,
            session: session,
          ),
          appBarActionsTrailing,
        ],
      ),
      body: _KeyboardAvoider(
        child: ListenableBuilder(
          listenable: Listenable.merge([conv, showThinking, _transitionDone]),
          builder: (context, _) {
            // Transition gate: defer heavy body content (message list, bottom
            // bar) until the push transition animation completes. During the
            // ~300ms animation, show a lightweight placeholder so the first
            // heavy build/layout frame doesn't compete with animation frames.
            if (!_transitionDone.value) {
              return const SizedBox.shrink();
            }
            // Granular cache invalidation (perfprobe-3): the store reports
            // which message ids' rendered content actually changed since the
            // last version bump. null → full clear (offline cache restore
            // etc.); a set → remove only those ids. Structural add/remove/
            // reorder keeps cached widgets valid (cache is id-keyed); stale
            // entries for removed ids are pruned in _pruneMessageCaches.
            final v = conv.messagesVersion;
            if (_lastMsgVersion != v) {
              _lastMsgVersion = v;
              final invalidations = conv.consumeContentInvalidations();
              if (invalidations == null) {
                _messageChildCache.clear();
              } else {
                for (final id in invalidations) {
                  _messageChildCache.remove(id);
                }
              }
            }
            // showThinking changes rendered content (reasoning show/hide) but
            // not messagesVersion — track it separately and invalidate.
            final st = showThinking.value;
            if (_lastShowThinking != st) {
              _lastShowThinking = st;
              _messageChildCache.clear();
            }
            if (conv.loading && !conv.loaded && conv.messages.isEmpty) {
              return const Center(child: CircularProgressIndicator());
            }
            if (!conv.loading && conv.error != null && conv.messages.isEmpty) {
              return Center(
                child: Text(
                  l(
                    context,
                  ).loadFailedDetail(friendlyMessage(l(context), conv.error!)),
                ),
              );
            }
            // Reversed CustomScrollView pins to the newest message (bottom) on
            // open. Slivers keep non-message rows out of the message index
            // space: bottom spacing / dynamic footer / messages / header.
            final msgs = conv.renderableMessages;
            if (_wasBusy && !conv.busy) _onBusyEnd(msgs);
            _wasBusy = conv.busy;
            _pruneMessageCaches(msgs);
            _scheduleFrameEval();
            int? dividerIndex;
            if (conv.gated) {
              for (var i = 0; i < msgs.length; i++) {
                if (msgs[i].created > conv.gateBaseline) continue;
                dividerIndex = i;
                break;
              }
              if (dividerIndex == 0 || dividerIndex == null) dividerIndex = null;
            }
            final effectiveDividerIndex = dividerIndex;
            final list = CustomScrollView(
              key: _listKey,
              reverse: true,
              controller: _scrollController,
              scrollCacheExtent: ScrollCacheExtent.pixels(_cacheExtent),
              slivers: [
                const SliverToBoxAdapter(child: SizedBox(height: 8)),
                SliverToBoxAdapter(child: _footerRow(conv)),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                  sliver: SliverList(
                    key: _sliverKey,
                    delegate: SliverChildBuilderDelegate(
                      (context, m) {
                        if (effectiveDividerIndex != null && m == effectiveDividerIndex) {
                          // reverse 列表 index 越大越靠上：Column 内先消息后
                          // 分隔条，屏幕上分隔条才落在实时尾部（下方）与缓存
                          // 基底（上方）的边界，而非 cache 块内部。
                          return Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _measuredMessage(msgs[m]),
                              const _GapSyncDivider(),
                            ],
                          );
                        }
                        return _measuredMessage(msgs[
                            effectiveDividerIndex != null && m > effectiveDividerIndex
                                ? m - 1
                                : m]);
                      },
                      childCount:
                          msgs.length + (effectiveDividerIndex != null ? 1 : 0),
                    ),
                  ),
                ),
                SliverToBoxAdapter(child: _headerRow(conv)),
              ],
            );
            final msgCount = msgs.length;
            if (msgCount != _lastMsgCount) {
              _lastMsgCount = msgCount;
              _scheduleAutoScroll();
            }
            final showFooter =
                conv.permissions.isNotEmpty ||
                conv.forms.isNotEmpty ||
                conv.todos.any((t) => !t.done);
            return Column(
              children: [
                Expanded(
                  child: Stack(
                    children: [
                      list,
                      Positioned(
                        right: 12,
                        bottom: 12,
                        child: _BackToTurnTopButton(
                          target: _backToTopTarget,
                          onTap: _scrollToRunTop,
                        ),
                      ),
                    ],
                  ),
                ),
                if (showFooter)
                  RepaintBoundary(
                    child: _FooterPanel(
                      todos: conv.todos,
                      permissions: conv.permissions,
                      questions: conv.forms,
                      store: conv,
                    ),
                  ),
                if (_cmdMode)
                  _CommandHints(
                    query: _ctl.text,
                    commands: serverStore.commandsNotifier.value,
                    loading:
                        serverStore.commandsRefreshing &&
                        serverStore.commandsNotifier.value.isEmpty,
                    onPick: _pickCommand,
                  ),
                _BackgroundTasksStrip(
                  parentSessionId: widget.sessionId,
                  onOpen: _showBackgroundTasks,
                ),
                RepaintBoundary(
                  child: _BottomBar(
                    sessionId: widget.sessionId,
                  directory: directory,
                  ctl: _ctl,
                  busy: conv.busy,
                  disabled: conv.workspaceMissing,
                  onAbort: () => _abort(directory),
                  onChanged: (t) {
                    conv.setDraft(
                      t,
                      shell: _shellMode,
                    ); // ← 开头：覆盖所有输入路径（含 shell 早退，CD-16）
                    if (_shellMode) {
                      if (t.isEmpty) {
                        setState(() => _shellMode = false);
                      }
                      return;
                    }
                    final mode = t.startsWith('/') && !t.contains(' ');
                    // Only (re)fetch when transitioning into command mode, not on
                    // every keystroke while typing — a degraded result retries on
                    // the next `/` input rather than hammering a flaky server.
                    if (mode &&
                        !_cmdMode &&
                        (!_cmdRefreshTriggered ||
                            serverStore.commandsDegraded)) {
                      _cmdRefreshTriggered = true;
                      _triggerCommandRefresh();
                    }
                    if (t == '!') {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (_ctl.text == '!') {
                          _ctl.clear();
                          setState(() => _shellMode = true);
                        }
                      });
                    }
                    setState(() => _cmdMode = mode);
                  },
                  onSend: _send,
                  farFromBottom: _farFromBottom,
                  onScrollToBottom: _scrollToBottom,
                  pending: _pending,
                  shellMode: _shellMode,
                  onExitShellMode: () => setState(() => _shellMode = false),
                  onPickAttachments: _pickAttachments,
                  onRemove: _removePending,
                ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  void _pickCommand(String cmd) {
    _ctl.text = '$cmd ';
    _ctl.selection = TextSelection.fromPosition(
      TextPosition(offset: _ctl.text.length),
    );
    setState(() => _cmdMode = false);
  }

  void _triggerCommandRefresh() {
    final dir = serverStore.sessionById(widget.sessionId)?.directory;
    serverStore.refreshCommands(directory: dir);
  }

  Future<void> _pickAttachments() async {
    List<XFile> picked;
    try {
      picked = await AttachmentPicker.pick(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l(context).attachmentPickFailed(e.toString())),
          ),
        );
      }
      return;
    }
    if (picked.isEmpty) return;
    // CR-6：并行 resolve（含压缩）；逐条收集错误
    final results = await Future.wait(
      picked.map((x) async {
        try {
          return (preview: await AttachmentPipeline.resolve(x), error: null);
        } on AttachmentTooLargeException catch (e) {
          return (preview: null, error: e);
        } catch (e) {
          return (preview: null, error: e);
        }
      }),
    );
    final resolved = <AttachmentPreview>[];
    for (final r in results) {
      if (r.preview != null) {
        resolved.add(r.preview!);
      } else if (r.error is AttachmentTooLargeException) {
        final e = r.error! as AttachmentTooLargeException;
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                l(context).attachmentTooLarge(
                  e.name,
                  (e.len / 1048576).toStringAsFixed(1),
                ),
              ),
            ),
          );
        }
      } else if (r.error != null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(l(context).attachmentReadFailed('${r.error}')),
            ),
          );
        }
      }
    }
    if (resolved.isNotEmpty) {
      setState(() => _pending.addAll(resolved.map(_PendingAttachment.new)));
    }
  }

  void _removePending(int i) => setState(() => _pending.removeAt(i));

  Future<void> _send() async {
    final text = _ctl.text.trim();
    final startsShell = text.startsWith('!') || _shellMode;
    if (startsShell && _pending.isNotEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l(context).attachmentShellIgnore)),
        );
      }
      return;
    }
    if (text.isEmpty && _pending.isEmpty) return;
    final conv = serverStore.conversationFor(widget.sessionId);
    final client = serverStore.client;
    if (conv == null || client == null) return;
    if (conv.workspaceMissing) return;
    serverStore.ensureSseForSession(widget.sessionId);
    final session = serverStore.sessionById(widget.sessionId);
    final directory = session?.directory;
    final pendingSnapshot = List<_PendingItem>.from(_pending);
    final attachments = pendingSnapshot
        .whereType<_PendingAttachment>()
        .map((e) => e.preview)
        .toList();
    final fileRefs = pendingSnapshot
        .whereType<_PendingFileRef>()
        .map((e) => e.ref)
        .toList();
    final shellModeWas = _shellMode;
    final displayText = _shellMode ? '!$text' : text;
    _ctl.clear();
    setState(() {
      _cmdMode = false;
      _shellMode = false;
      _pending.clear();
    });
    try {
      if (startsShell) {
        final command = shellModeWas ? text : text.substring(1).trim();
        if (command.isNotEmpty) {
          conv.addOptimisticUserMessage(displayText);
          serverStore.reflectPreviewFrom(widget.sessionId);
          await client.shell(
            widget.sessionId,
            command: command,
          );
          conv.setStatus('busy');
        }
      } else {
        var isCommand = false;
        if (text.startsWith('/')) {
          await serverStore.refreshCommands(directory: directory);
          final firstSpace = text.indexOf(' ');
          final cmdToken =
              (firstSpace == -1
                      ? text.substring(1)
                      : text.substring(1, firstSpace))
                  .toLowerCase();
          final matched = serverStore.commandsNotifier.value.firstWhere(
            (c) => c.slash.toLowerCase() == '/$cmdToken',
            orElse: () => const CommandInfo(name: ''),
          );
          if (matched.name.isNotEmpty) {
            isCommand = true;
            final arguments = firstSpace == -1
                ? ''
                : text.substring(firstSpace + 1).trim();
            final cmdFiles = <Map<String, dynamic>>[
              for (final a in attachments)
                {
                  'uri': a.dataUrl,
                  'name': a.filename,
                },
              for (final r in fileRefs)
                {'uri': 'file://${r.absolute}', 'name': r.filename},
            ];
            conv.addOptimisticUserMessage(
              text,
              attachments: attachments,
              fileRefs: fileRefs,
            );
            serverStore.reflectPreviewFrom(widget.sessionId);
            final totalLen = cmdFiles.fold<int>(
              0,
              (s, p) => (p['uri']?.toString().length ?? 0) + s,
            );
            final sendTimeout = totalLen > 2 * 1024 * 1024
                ? const Duration(seconds: 120)
                : null;
            if (matched.skill) {
              await client.prompt(
                widget.sessionId,
                text: text,
                skills: [
                  {'id': matched.name, 'name': matched.name},
                ],
                files: cmdFiles,
                sendTimeout: sendTimeout,
              );
            } else {
              await client.command(
                widget.sessionId,
                command: matched.name,
                arguments: arguments,
                files: cmdFiles,
                sendTimeout: sendTimeout,
              );
            }
            conv.setStatus('busy');
          }
        }
        if (!isCommand) {
          final files = <Map<String, dynamic>>[
            for (final a in attachments)
              {
                'uri': a.dataUrl,
                'name': a.filename,
              },
            for (final r in fileRefs)
              {'uri': 'file://${r.absolute}', 'name': r.filename},
          ];
          conv.addOptimisticUserMessage(
            text,
            attachments: attachments,
            fileRefs: fileRefs,
          );
          serverStore.reflectPreviewFrom(widget.sessionId);
          final totalLen = files.fold<int>(
            0,
            (s, p) => (p['uri']?.toString().length ?? 0) + s,
          );
          await client.prompt(
            widget.sessionId,
            text: text,
            files: files,
            sendTimeout: totalLen > 2 * 1024 * 1024
                ? const Duration(seconds: 120)
                : null,
          );
          conv.setStatus('busy');
        }
      }
      conv.setDraft('', shell: false); // 发送成功 → 清除草稿（与成功路径对称）
      conv.persistDraft();
    } catch (e) {
      final hadOptimistic = conv.messages.any((m) => m.optimistic);
      conv.removeOptimisticMessages();
      serverStore.reflectPreviewFrom(widget.sessionId);
      if (hadOptimistic) {
        _ctl.text = shellModeWas ? text : displayText;
        setState(() {
          _shellMode = shellModeWas;
          _cmdMode = false;
          _pending
            ..clear()
            ..addAll(pendingSnapshot);
        });
        conv.setDraft(shellModeWas ? text : displayText, shell: shellModeWas);
        conv.persistDraft(); // CD-2：失败回填草稿并落盘，与成功路径对称
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                l(context).sendFailed(friendlyMessage(l(context), e)),
              ),
            ),
          );
        }
      }
    }
    _scheduleAutoScroll();
  }

  /// 当前会话的「用户后台任务」= running 直系子会话中、非工具型 tool part 承载者
  /// （design-subagent-background §识别）。
  List<SessionModel> _runningBackgroundTasks() {
    final conv = serverStore.conversationForRead(widget.sessionId);
    if (conv == null) return const [];
    return serverStore
        .runningChildSessionsOf(widget.sessionId)
        .where((c) => !conv.isToolFormChild(c))
        .toList(growable: false);
  }

  Future<void> _showBackgroundTasks() async {
    if (_runningBackgroundTasks().isEmpty) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListenableBuilder(
          listenable: serverStore,
          builder: (ctx, _) {
            final live = _runningBackgroundTasks();
            if (live.isEmpty) {
              return Padding(
                padding: const EdgeInsets.all(20),
                child: Text(l(ctx).bgTaskDone),
              );
            }
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final t in live)
                  ListTile(
                    dense: true,
                    leading:
                        const Icon(Icons.rocket_launch_outlined, size: 18),
                    title: Text(
                      t.title.isNotEmpty ? t.title : t.id,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: (t.agent ?? '').isEmpty
                        ? null
                        : Text(t.agent!, style: const TextStyle(fontSize: 11)),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.visibility_outlined, size: 18),
                          tooltip: l(ctx).bgTaskView,
                          onPressed: () {
                            Navigator.of(ctx).pop();
                            _showTaskDetail(t.id, t.title);
                          },
                        ),
                        IconButton(
                          icon:
                              const Icon(Icons.stop_circle_outlined, size: 18),
                          tooltip: l(ctx).bgTaskStop,
                          onPressed: () => _stopBackgroundTask(t.id),
                        ),
                      ],
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _stopBackgroundTask(String childId) async {
    final client = serverStore.client;
    if (client == null) return;
    try {
      await client.interrupt(childId);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content:
              Text(l(context).abortFailed(friendlyMessage(l(context), e))),
        ),
      );
    }
  }

  Future<void> _showTaskDetail(String childId, String label) async {
    serverStore.loadChildSessionMessages(childId);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SizedBox(
        height: MediaQuery.sizeOf(ctx).height * 0.6,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                label.isNotEmpty ? label : childId,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
            Expanded(
              child: _SubagentBody(
                childSessionId: childId,
                parentSessionId: widget.sessionId,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<bool> _abort(String directory) async {
    final client = serverStore.client;
    if (client == null) return false;
    try {
      await client.interrupt(widget.sessionId);
      return true;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              l(context).abortFailed(friendlyMessage(l(context), e)),
            ),
          ),
        );
      }
      return false;
    }
  }

  Widget _message(DisplayMessage m, {required bool stable}) {
    return Padding(
      key: ValueKey(m.id),
      padding: const EdgeInsets.only(right: 24, top: 10, bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _parts(m.parts, user: false, stable: stable),
          if (m.error != null) _errorBanner(m.error!),
        ],
      ),
    );
  }

  Widget _errorBanner(Map<String, dynamic> error, {VoidCallback? onDismiss}) {
    final name = (error['name'] ?? 'Error').toString();
    final message = _extractErrorMessage(error) ?? '';
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF85149).withAlpha(15),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFF85149).withAlpha(60)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, size: 16, color: Color(0xFFF85149)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message.isNotEmpty ? '$name: $message' : name,
              style: const TextStyle(fontSize: 13, color: Color(0xFFF85149)),
            ),
          ),
          if (onDismiss != null) ...[
            const SizedBox(width: 8),
            InkWell(
              onTap: onDismiss,
              child: const Icon(
                Icons.close,
                size: 16,
                color: Color(0xFFF85149),
              ),
            ),
          ],
        ],
      ),
    );
  }

  String? _extractErrorMessage(Map<String, dynamic> error) {
    final data = error['data'];
    if (data is Map) {
      final msg = data['message']?.toString();
      if (msg != null && msg.isNotEmpty) return msg;
      final err = data['error']?.toString();
      if (err != null && err.isNotEmpty) return err;
      // Only dump data if it contains at least one meaningful value.
      if (data.values.any((v) => v != null && v.toString().isNotEmpty)) {
        return data.toString();
      }
    } else if (data is String && data.isNotEmpty) {
      return data;
    }
    for (final key in ['message', 'error', 'msg', 'detail']) {
      final v = error[key]?.toString();
      if (v != null && v.isNotEmpty) return v;
    }
    // Only dump the raw map if it contains unexpected fields beyond name/data.
    if (error.keys.any((k) => k != 'name' && k != 'data')) {
      return error.toString();
    }
    return null;
  }

  void _scheduleAutoScroll() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      // Reversed list: the newest (bottom) is at offset 0.
      if (_scrollController.position.pixels <= _kAutoScrollPixels) {
        _scrollController.jumpTo(0);
      }
    });
  }

  Color _userBubbleColor() =>
      Theme.of(context).extension<AppColors>()!.userBubble;

  Widget _parts(
    List<DisplayPart> parts, {
    required bool user,
    required bool stable,
    VoidCallback? onTextTap,
  }) {
    final visible = <DisplayPart>[];
    for (final p in parts) {
      if (user && p.type != 'text' && p.type != 'file' && p.type != 'subtask') {
        continue;
      }
      if (p.type == 'text' && p.text.trim().isEmpty) continue;
      visible.add(p);
    }
    final children = <Widget>[];
    for (var i = 0; i < visible.length; i++) {
      children.add(
        _part(
          visible[i],
          user: user,
          isFirst: i == 0,
          stable: stable,
          onTextTap: onTextTap,
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  Widget _part(
    DisplayPart p, {
    required bool user,
    bool isFirst = false,
    required bool stable,
    VoidCallback? onTextTap,
  }) {
    switch (p.type) {
      case 'subtask':
        final commandName = p.command ?? 'subtask';
        if (!stable && !p.settled) {
          return Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              p.text.isEmpty
                  ? 'subtask: $commandName'
                  : 'subtask: $commandName\n\n${p.text}',
              style: _streamingTextStyle(user),
            ),
          );
        }
        final label = '**subtask: $commandName**';
        final body = p.text;
        final combined = body.isEmpty ? label : '$label\n\n$body';
        return _markdownPart(
          combined,
          user: user,
          settled: stable || p.settled,
          cacheKey: p.id,
          onTextTap: onTextTap,
        );
      case 'text':
        return _markdownPart(
          p.text,
          user: user,
          settled: stable || p.settled,
          cacheKey: p.id,
          onTextTap: onTextTap,
        );
      case 'reasoning':
        if (!showThinking.value) return const SizedBox.shrink();
        return _Reasoning(
          key: PageStorageKey(p.id),
          text: p.text,
          partId: p.id,
        );
      case 'tool':
        // 工具型 subagent 保留 tool part 面板形态（design-subagent-status）：
        // 前台阻塞调用、停在流尾、composer 停止可取消，不进后台任务条。
        if (p.tool == 'task' || p.tool == 'subagent') {
          return _SubagentPanel(
            key: PageStorageKey(p.id),
            part: p,
            parentSessionId: widget.sessionId,
          );
        }
        return _ToolChip(key: PageStorageKey(p.id), part: p);
      case 'file':
        return _FileChip(
          key: ValueKey(p.id),
          part: p,
          user: user,
          isFirst: isFirst,
          sessionId: widget.sessionId,
          directory: serverStore.sessionById(widget.sessionId)?.directory,
        );
      default:
        return const SizedBox.shrink();
    }
  }

  MarkdownStyleSheet? _mdStyleUser;
  MarkdownStyleSheet? _mdStyleAssistant;

  Widget _markdownPart(
    String data, {
    required bool user,
    required bool settled,
    String? cacheKey,
    VoidCallback? onTextTap,
  }) {
    if (!settled) {
      if (data.isEmpty) return const SizedBox.shrink();
      final overLimit = data.length > _kMarkdownMaxChars;
      final effective =
          overLimit ? _truncatedText(data, _kMarkdownMaxChars) : data;
      return Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          effective,
          style: _streamingTextStyle(user),
        ),
      );
    }
    final sheet = user ? _mdStyleUser : _mdStyleAssistant;
    final overLimit = data.length > _kMarkdownMaxChars;
    final effective =
        overLimit ? _truncatedText(data, _kMarkdownMaxChars) : data;
    final sig = '$user\x1f$effective';
    if (cacheKey != null) {
      final cached = _partWidgetCache.lookup(cacheKey, sig);
      if (cached != null) return cached;
    }
    final linkified =
        _autolinkCache.putIfAbsent(effective, () => autolinkMarkdownLinks(effective));
    if (_autolinkCache.length >= _kAutolinkCacheMax) {
      _autolinkCache.remove(_autolinkCache.keys.first);
    }
    final built = Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          MarkdownBody(
            data: linkified,
            selectable: !overLimit,
            softLineBreak: user,
            onTapLink: (text, href, title) => _onMdLink(href),
            onTapText: onTextTap,
            styleSheet: sheet ?? _buildMdStyle(user: user),
          ),
          if (overLimit)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                l(context).messageTruncated,
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.outline,
                ),
              ),
            ),
        ],
      ),
    );
    if (cacheKey != null) {
      _partWidgetCache.store(cacheKey, sig, built);
    }
    return built;
  }

  /// 流式降级文本样式：对齐 MarkdownBody 的 p 档（fontSize 14 / height 1.45），
  /// 用户气泡内沿用气泡配色。仅用于未收尾 part，收尾后由 Markdown 接管。
  TextStyle _streamingTextStyle(bool user) {
    final p = _messagePalette(context, user);
    return TextStyle(fontSize: 14, height: 1.45, color: p.text);
  }

  MarkdownStyleSheet _buildMdStyle({required bool user}) =>
      buildConversationMdStyle(context, user: user);

  void _onMdLink(String? href) {
    if (href == null || href.isEmpty) return;
    if (href.startsWith('ob-file:///')) {
      _openLinkedFile(href);
      return;
    }
    _openExternalLink(href);
  }

  void _openLinkedFile(String href) {
    final decoded = decodeFileHref(href);
    if (decoded == null) return;
    final (raw, line) = decoded;
    final directory =
        serverStore.sessionById(widget.sessionId)?.directory ?? '';
    final rel = resolveProjectPath(raw, directory);
    if (rel == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l(context).fileLinkNotInProject)));
      return;
    }
    context.push(
      '/session/${widget.sessionId}/files'
      '?directory=${Uri.encodeQueryComponent(directory)}',
      extra: FileBrowsingSnapshot(
        openFiles: [
          OpenFileEntry(
            path: rel,
            scrollOffset: 0,
            wrap: false,
            showSource: line != null,
            initialLine: line,
          ),
        ],
        peek: true,
      ),
    );
  }

  Future<void> _openExternalLink(String? href) =>
      openExternalLink(context, href);
}

Future<void> openExternalLink(BuildContext context, String? href) async {
  if (href == null || href.isEmpty) return;
  if (href.startsWith('#')) return;
  final uri = Uri.tryParse(href);
  if (uri == null) return;
  try {
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l(context).linkOpenFailed)));
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l(context).linkOpenFailedDetail(e.toString())),
        ),
      );
    }
  }
}

class _TodoCard extends StatelessWidget {
  final List<Todo> todos;
  final bool collapsed;
  final VoidCallback? onToggle;
  const _TodoCard({required this.todos, this.collapsed = false, this.onToggle});

  @override
  Widget build(BuildContext context) {
    final done = todos.where((t) => t.done).length;
    final pct = todos.isEmpty ? 0.0 : done / todos.length;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: onToggle,
            child: Row(
              children: [
                const Icon(Icons.checklist, size: 16),
                const SizedBox(width: 6),
                Text(
                  l(context).todoTitle,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Text(
                  '$done/${todos.length}',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.outline,
                  ),
                ),
                if (onToggle != null) ...[
                  const SizedBox(width: 6),
                  Icon(
                    collapsed ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: Theme.of(context).colorScheme.outline,
                  ),
                ],
              ],
            ),
          ),
          if (!collapsed)
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight:
                    MediaQuery.sizeOf(context).height *
                    _kFooterCardContentHeightFactor,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 10),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: pct,
                        minHeight: 5,
                        backgroundColor: const Color(0xFF23272E),
                        valueColor: AlwaysStoppedAnimation(
                          Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    ...todos.map(_todoRow),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _todoRow(Todo t) {
    final icon = t.cancelled
        ? Icons.cancel
        : t.done
        ? Icons.check_box
        : t.active
        ? Icons.indeterminate_check_box
        : Icons.check_box_outline_blank;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              t.content,
              style: TextStyle(
                fontSize: 12.5,
                decoration: t.done
                    ? TextDecoration.lineThrough
                    : TextDecoration.none,
                color: t.done ? const Color(0xFF8B949E) : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FooterPanel extends StatefulWidget {
  final List<Todo> todos;
  final List<Permission> permissions;
  final List<FormInfo> questions;
  final ConversationStore store;
  const _FooterPanel({
    required this.todos,
    required this.permissions,
    required this.questions,
    required this.store,
  });

  @override
  State<_FooterPanel> createState() => _FooterPanelState();
}

class _FooterPanelState extends State<_FooterPanel> {
  bool _todoExpanded = false;

  @override
  Widget build(BuildContext context) {
    final totalPending = widget.permissions.length + widget.questions.length;
    final children = <Widget>[];
    if (widget.permissions.isNotEmpty) {
      children.add(
        _PermissionCard(
          key: ValueKey(widget.permissions.first.id),
          permission: widget.permissions.first,
          store: widget.store,
          queueTotal: totalPending,
        ),
      );
    } else if (widget.questions.isNotEmpty) {
      children.add(
        _FormCard(
          key: ValueKey(widget.questions.first.id),
          form: widget.questions.first,
          store: widget.store,
          queueTotal: totalPending,
        ),
      );
    }
    if (widget.todos.isNotEmpty && totalPending == 0) {
      children.add(
        _TodoCard(
          todos: widget.todos,
          collapsed: !_todoExpanded,
          onToggle: () => setState(() => _todoExpanded = !_todoExpanded),
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(mainAxisSize: MainAxisSize.min, children: children),
      ),
    );
  }
}

const int kToolCodeMaxChars = 8000;
const int _kMarkdownMaxChars = 16000;

String _truncatedText(String s, int limit) {
  if (s.length <= limit) return s;
  var end = limit;
  final u = s.codeUnitAt(end - 1);
  if (u >= 0xD800 && u <= 0xDBFF) end--;
  return s.substring(0, end);
}

/// 已收尾 part 的 Markdown widget 实例缓存：流式消息（finish==null）不走
/// _messageChildCache 整条实例缓存，逐 token 重建会连带已收尾 part 的
/// MarkdownBody 全量重解析；按 part id + 内容签名缓存实例，等值复用让
/// element 树短路跳过整个子树。随 didChangeDependencies 清空（theme/locale
/// 变化），容量上限淘汰防泄漏。
class _PartWidgetCache {
  static const _max = 128;
  final _sigs = <String, String>{};
  final _widgets = <String, Widget>{};

  Widget? lookup(String key, String sig) =>
      _sigs[key] == sig ? _widgets[key] : null;

  void store(String key, String sig, Widget widget) {
    if (!_widgets.containsKey(key) && _widgets.length >= _max) {
      final oldest = _widgets.keys.first;
      _widgets.remove(oldest);
      _sigs.remove(oldest);
    }
    _sigs[key] = sig;
    _widgets[key] = widget;
  }

  void clear() {
    _sigs.clear();
    _widgets.clear();
  }
}

Widget toolCodeBlock(BuildContext context, String body, AppColors appColors) {
  var text = body;
  if (text.endsWith('\n')) text = text.substring(0, text.length - 1);
  int? omitted;
  if (text.length > kToolCodeMaxChars) {
    final capped = _truncatedText(text, kToolCodeMaxChars);
    omitted = text.length - capped.length;
    text = capped;
  }
  return Container(
    width: double.infinity,
    clipBehavior: Clip.hardEdge,
    decoration: BoxDecoration(
      color: appColors.codeBackground,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: appColors.border),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: omitted == null
              ? const EdgeInsets.all(12)
              : const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: Text(
            text,
            style: AppTheme.mono.copyWith(fontSize: 13, color: appColors.code),
          ),
        ),
        if (omitted != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
            child: Text(
              l(context).toolOutputTruncated(omitted.toString()),
              style: TextStyle(
                fontSize: 11,
                color: appColors.code.withValues(alpha: 0.7),
              ),
            ),
          ),
      ],
    ),
  );
}

const int _kToolCopyFileThreshold = 512 * 1024;

Future<void> copyToolPartContent(BuildContext context, DisplayPart part) async {
  final buf = StringBuffer();
  final input = part.toolInput;
  if (input != null && input.isNotEmpty) {
    buf.writeln(const JsonEncoder.withIndent('  ').convert(input));
  }
  final output = part.toolOutput;
  if (output != null && output.isNotEmpty) {
    if (buf.isNotEmpty) buf.writeln();
    buf.write(output);
  }
  final error = part.toolError;
  if (part.toolStatus == 'error' && error != null && error.isNotEmpty) {
    if (buf.isNotEmpty) buf.writeln();
    buf.write(error);
  }
  if (buf.isEmpty) return;
  final text = buf.toString();
  final loc = l(context);
  if (text.length > _kToolCopyFileThreshold) {
    // Android 剪贴板对 MB 级内容会静默截断/失败——大内容改走临时文件 +
    // 系统分享面板（用户可存文件/发到别处），保留完整内容。
    try {
      final tmp = await getTemporaryDirectory();
      final file = File(
          '${tmp.path}/tool-part-${DateTime.now().millisecondsSinceEpoch}.txt');
      await file.writeAsString(text, flush: true);
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path)]),
      );
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(loc.copyFailed)),
        );
      }
    }
    return;
  }
  try {
    await Clipboard.setData(ClipboardData(text: text));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(loc.copied)),
      );
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(loc.copyFailed)),
      );
    }
  }
}

void _syncReversedScroll(BuildContext context, GlobalKey key, double dv) {
  if (dv == 0) return;
  final content = key.currentContext?.findRenderObject();
  if (content is! RenderBox || !content.attached) return;
  final h = content.size.height;
  if (h <= 0) return;
  final pos = context.findAncestorStateOfType<ScrollableState>()?.position;
  if (pos == null || !pos.hasContentDimensions) return;
  final item = context.findRenderObject();
  final vp = RenderAbstractViewport.maybeOf(content);
  if (item is! RenderBox || vp is! RenderBox || !item.attached) return;
  final top = item.localToGlobal(Offset.zero, ancestor: vp).dy;
  final growth = h * dv;
  final corr = dv > 0
      ? math.max(0.0, growth - math.max(0.0, top))
      : math.min(0.0, growth + math.max(0.0, -top));
  if (corr == 0) return;
  final target = math.max(pos.pixels + corr, pos.minScrollExtent);
  if (target == pos.pixels) return;
  pos.correctPixels(target);
}

class _CollapsibleReveal extends StatelessWidget {
  final Animation<double> sizeFactor;
  final Widget child;
  const _CollapsibleReveal({required this.sizeFactor, required this.child});

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: SizeTransition(
        sizeFactor: sizeFactor,
        axis: Axis.horizontal,
        alignment: Alignment.centerLeft,
        child: SizeTransition(
          sizeFactor: sizeFactor,
          alignment: Alignment.topCenter,
          child: child,
        ),
      ),
    );
  }
}

class _Reasoning extends StatefulWidget {
  final String text;
  final String partId;
  const _Reasoning({super.key, required this.text, required this.partId});

  @override
  State<_Reasoning> createState() => _ReasoningState();
}

class _ReasoningState extends State<_Reasoning>
    with SingleTickerProviderStateMixin {
  bool _expanded = false;
  final GlobalKey _contentKey = GlobalKey();
  double _lastV = 0;
  late final AnimationController _ctrl = AnimationController(
    duration: const Duration(milliseconds: 150),
    vsync: this,
  )..addListener(_onAnimate);
  late final Animation<double> _curved = _ctrl.drive(
    CurveTween(curve: Curves.easeOut),
  );

  Object get _expansionStorageKey => 'reasoning_expanded:${widget.partId}';

  @override
  void initState() {
    super.initState();
    _expanded =
        PageStorage.maybeOf(
          context,
        )?.readState(context, identifier: _expansionStorageKey) ==
        true;
    if (_expanded) {
      _lastV = 1.0;
      _ctrl.value = 1.0;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _onAnimate() {
    final v = _curved.value;
    _syncReversedScroll(context, _contentKey, v - _lastV);
    _lastV = v;
  }

  void _toggle() {
    setState(() {
      _expanded = !_expanded;
      if (_expanded) {
        _ctrl.forward();
      } else {
        _ctrl.reverse();
      }
    });
    PageStorage.maybeOf(
      context,
    )?.writeState(context, _expanded, identifier: _expansionStorageKey);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.outline;
    return Container(
      margin: const EdgeInsets.only(top: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: _toggle,
        onLongPress: () {
          if (widget.text.isEmpty) return;
          Clipboard.setData(ClipboardData(text: widget.text));
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(l(context).copied)));
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: _expanded ? MainAxisSize.max : MainAxisSize.min,
                children: [
                  Icon(Icons.psychology_outlined, size: 14, color: muted),
                  const SizedBox(width: 6),
                  Builder(
                    builder: (context) {
                      final label = Text(
                        l(context).reasoning,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w400,
                          color: muted,
                        ),
                      );
                      return _expanded ? Flexible(child: label) : label;
                    },
                  ),
                  const SizedBox(width: 6),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: muted,
                  ),
                ],
              ),
              _CollapsibleReveal(
                sizeFactor: _curved,
                child: Padding(
                  key: _contentKey,
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    widget.text,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: muted,
                      fontStyle: FontStyle.italic,
                      height: 1.45,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ToolChip extends StatefulWidget {
  final DisplayPart part;
  const _ToolChip({super.key, required this.part});

  @override
  State<_ToolChip> createState() => _ToolChipState();
}

class _ToolChipState extends State<_ToolChip>
    with SingleTickerProviderStateMixin {
  bool _expanded = false;
  final GlobalKey _contentKey = GlobalKey();
  final GlobalKey _headerKey = GlobalKey();
  double _lastV = 0;
  // Header width captured at toggle time (a gesture callback), never read
  // during build — reading `.size` during build throws.
  double _headerW = 0.0;
  late final AnimationController _ctrl = AnimationController(
    duration: const Duration(milliseconds: 150),
    vsync: this,
  )..addListener(_onAnimate);
  late final Animation<double> _curved = _ctrl.drive(
    CurveTween(curve: Curves.easeOut),
  );

  Object get _expansionStorageKey => 'toolchip_expanded:${widget.part.id}';

  @override
  void initState() {
    super.initState();
    _expanded =
        PageStorage.maybeOf(
          context,
        )?.readState(context, identifier: _expansionStorageKey) ==
        true;
    if (_expanded) {
      _lastV = 1.0;
      _ctrl.value = 1.0;
      // Capture header width after first frame so that a later collapse
      // animation interpolates from the real header width, not 0.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _headerW = _headerKey.currentContext?.size?.width ?? _headerW;
        }
      });
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _onAnimate() {
    final v = _curved.value;
    _syncReversedScroll(context, _contentKey, v - _lastV);
    _lastV = v;
  }

  void _toggle() {
    // Capture the laid-out header width here (gesture callback), since it
    // cannot be read during build.
    _headerW = _headerKey.currentContext?.size?.width ?? _headerW;
    setState(() {
      _expanded = !_expanded;
      if (_expanded) {
        _ctrl.forward();
      } else {
        _ctrl.reverse();
      }
    });
    PageStorage.maybeOf(
      context,
    )?.writeState(context, _expanded, identifier: _expansionStorageKey);
  }

  @override
  Widget build(BuildContext context) {
    final part = widget.part;
    final theme = Theme.of(context);
    final (icon, color) = switch (part.toolStatus) {
      'completed' => (Icons.check_circle, const Color(0xFF3FB950)),
      'running' => (Icons.play_arrow, const Color(0xFF4ADE80)),
      'error' => (Icons.error, const Color(0xFFF85149)),
      _ => (Icons.hourglass_top, const Color(0xFF8B949E)),
    };
    return Container(
      margin: const EdgeInsets.only(top: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: _toggle,
        onLongPress: () => copyToolPartContent(context, part),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              LayoutBuilder(
                builder: (context, c) {
                  final summaryStyle = TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w400,
                    color: theme.colorScheme.outline,
                  );
                  return Row(
                    key: _headerKey,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon, size: 15, color: color),
                      const SizedBox(width: 6),
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: math.max(0.0, c.maxWidth - 45),
                        ),
                        child: Text(
                          part.toolSummary,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: summaryStyle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Icon(
                        _expanded ? Icons.expand_less : Icons.expand_more,
                        size: 18,
                        color: theme.colorScheme.outline,
                      ),
                    ],
                  );
                },
              ),
              LayoutBuilder(
                builder: (context, c) {
                  return AnimatedBuilder(
                    animation: _curved,
                    builder: (context, child) {
                      return SizedBox(
                        width:
                            _headerW + (c.maxWidth - _headerW) * _curved.value,
                        child: SizeTransition(
                          sizeFactor: _curved,
                          alignment: Alignment.topCenter,
                          child: child,
                        ),
                      );
                    },
                    child: Column(
                      key: _contentKey,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: _expandedChildren(part, theme, c.maxWidth),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _expandedChildren(
    DisplayPart part,
    ThemeData theme,
    double maxWidth,
  ) {
    final appColors = theme.extension<AppColors>()!;
    final input = part.toolInput;
    final output = part.toolOutput;
    final error = part.toolError;
    final children = <Widget>[];
    if (input != null && input.isNotEmpty) {
      children.add(const SizedBox(height: 8));
      children.add(
        toolCodeBlock(
          context,
          const JsonEncoder.withIndent('  ').convert(input),
          appColors,
        ),
      );
    }
    if (output != null && output.isNotEmpty) {
      children.add(const SizedBox(height: 8));
      children.add(toolCodeBlock(context, output, appColors));
    }
    if (part.toolStatus == 'error' && error != null && error.isNotEmpty) {
      children.add(const SizedBox(height: 8));
      children.add(
        UnconstrainedBox(
          alignment: Alignment.centerLeft,
          clipBehavior: Clip.hardEdge,
          child: SizedBox(
            width: maxWidth,
            child: Text(
              error,
              style: const TextStyle(
                fontSize: 12,
                color: Color(0xFFF85149),
                height: 1.45,
              ),
            ),
          ),
        ),
      );
    }
    return children;
  }
}

/// subagent 工作状态面板（design-subagent-status）：task 工具的专用渲染——
/// 替代 _ToolChip，在主消息流中内嵌子会话消息流。收起态 = agent 名 +
/// 状态图标 + 描述摘要（同 ToolChip 收起观感）；展开态 = 独立滚动（滚动条
/// 隐藏、贴底跟随）的子会话消息列表，宽度与消息区一致。
class _SubagentPanel extends StatefulWidget {
  final DisplayPart part;
  final String parentSessionId;
  const _SubagentPanel({
    super.key,
    required this.part,
    required this.parentSessionId,
  });

  @override
  State<_SubagentPanel> createState() => _SubagentPanelState();
}

class _SubagentPanelState extends State<_SubagentPanel>
    with SingleTickerProviderStateMixin {
  bool _expanded = false;
  final GlobalKey _contentKey = GlobalKey();
  final GlobalKey _headerKey = GlobalKey();
  double _lastV = 0;
  double _headerW = 0.0;
  late final AnimationController _ctrl = AnimationController(
    duration: const Duration(milliseconds: 150),
    vsync: this,
  )..addListener(_onAnimate);
  late final Animation<double> _curved = _ctrl.drive(
    CurveTween(curve: Curves.easeOut),
  );

  /// 已触发 REST 快照的子会话 id（ref 而非布尔：childSessionId 漂移
  /// ——启发式命中在先 → metadata.sessionId 到达切换——时对新 id 重新
  /// 触发）。收起即重置：面板无错误态渲染，再展开是 REST 失败后的
  /// 唯一重试入口。
  String? _loadedChildId;

  Object get _expansionStorageKey => 'subagent_expanded:${widget.part.id}';

  @override
  void initState() {
    super.initState();
    _expanded =
        PageStorage.maybeOf(
          context,
        )?.readState(context, identifier: _expansionStorageKey) ==
        true;
    if (_expanded) {
      _lastV = 1.0;
      _ctrl.value = 1.0;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _headerW = _headerKey.currentContext?.size?.width ?? _headerW;
        }
      });
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _onAnimate() {
    final v = _curved.value;
    _syncReversedScroll(context, _contentKey, v - _lastV);
    _lastV = v;
  }

  void _toggle() {
    _headerW = _headerKey.currentContext?.size?.width ?? _headerW;
    setState(() {
      _expanded = !_expanded;
      if (_expanded) {
        _ctrl.forward();
      } else {
        _ctrl.reverse();
        _loadedChildId = null;
      }
    });
    PageStorage.maybeOf(
      context,
    )?.writeState(context, _expanded, identifier: _expansionStorageKey);
  }

  @override
  Widget build(BuildContext context) {
    final part = widget.part;
    final theme = Theme.of(context);
    final loc = l(context);
    final status = part.toolStatus ?? '';

    // 子会话 ID 来源（design-subagent-status §D3）：
    // 1. tool.state.metadata.sessionId（running/completed 后 server 写入）
    // 2. 降级：findChildSession 按 parentID + description 启发式匹配
    final metaSid = part.toolMetadata?['sessionId']?.toString();
    final description = part.toolInput?['description']?.toString() ?? '';
    final subagentType = part.toolInput?['subagent_type']?.toString() ?? '';
    final childSessionId = (metaSid != null && metaSid.isNotEmpty)
        ? metaSid
        : serverStore
            .findChildSession(widget.parentSessionId, description: description)
            ?.id;

    // 展开挂载后触发 REST 快照（SSE 已累积则 store 内部跳过）。post-frame
    // 执行 store 变更（不在 build 期间通知），随后 setState 让 body 拿到
    // 刚创建的 conv 挂 ListenableBuilder——conv 创建本身不通知 store，
    // 不补这一帧面板会停在「加载中」。
    if (_expanded &&
        childSessionId != null &&
        _loadedChildId != childSessionId) {
      _loadedChildId = childSessionId;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_expanded) return;
        serverStore.loadChildSessionMessages(childSessionId);
        setState(() {});
      });
    }

    final agentLabel = subagentType.isNotEmpty
        ? subagentType[0].toUpperCase() + subagentType.substring(1)
        : loc.convDefaultTitle;
    final summary = switch (status) {
      'completed' => (part.toolTitle?.isNotEmpty ?? false)
          ? part.toolTitle!
          : description,
      'error' => part.toolError ?? description,
      _ => description,
    };
    final (icon, color) = switch (status) {
      'completed' => (Icons.check_circle, const Color(0xFF3FB950)),
      'running' => (Icons.play_arrow, const Color(0xFF4ADE80)),
      'error' => (Icons.error, const Color(0xFFF85149)),
      _ => (Icons.hourglass_top, const Color(0xFF8B949E)),
    };

    return Container(
      margin: const EdgeInsets.only(top: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: _toggle,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              LayoutBuilder(
                builder: (context, c) {
                  return Row(
                    key: _headerKey,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon, size: 15, color: color),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          agentLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                      ),
                      if (summary.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            summary,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w400,
                              color: theme.colorScheme.outline,
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(width: 6),
                      Icon(
                        _expanded ? Icons.expand_less : Icons.expand_more,
                        size: 18,
                        color: theme.colorScheme.outline,
                      ),
                    ],
                  );
                },
              ),
              LayoutBuilder(
                builder: (context, c) {
                  return AnimatedBuilder(
                    animation: _curved,
                    builder: (context, child) {
                      return SizedBox(
                        width:
                            _headerW + (c.maxWidth - _headerW) * _curved.value,
                        child: SizeTransition(
                          sizeFactor: _curved,
                          alignment: Alignment.topCenter,
                          child: child,
                        ),
                      );
                    },
                    child: Column(
                      key: _contentKey,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // 收起动画期间保持挂载（SizeTransition 有内容可缩），
                        // 静止收起态才卸载——同 _ToolChip 的展开语义。
                        if (_expanded || _ctrl.isAnimating)
                          _SubagentBody(
                            childSessionId: childSessionId,
                            parentSessionId: widget.parentSessionId,
                          ),
                      ],
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// SubagentPanel 展开态的子会话消息流。独立滚动（贴底跟随、滚动条隐藏），
/// 复用 _ToolChip 渲染子会话内的工具 part；text 走稳定 Markdown 路径
/// （子会话不进 _messageChildCache 实例缓存——面板高度有界、条目少）。
/// 常驻后台任务条（design-subagent-background §D1）：仅当存在 running 的
/// 用户后台任务时显示，全部完成即消失；点击进入任务列表（查看 / 停止）。
class _BackgroundTasksStrip extends StatelessWidget {
  final String parentSessionId;
  final VoidCallback onOpen;
  const _BackgroundTasksStrip({
    required this.parentSessionId,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final conv = serverStore.conversationForRead(parentSessionId);
    final listenable = conv == null
        ? serverStore
        : Listenable.merge([serverStore, conv]);
    return ListenableBuilder(
      listenable: listenable,
      builder: (context, _) {
        final count = serverStore
            .runningChildSessionsOf(parentSessionId)
            .where((c) => conv == null || !conv.isToolFormChild(c))
            .length;
        if (count == 0) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
          child: Material(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: onOpen,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                child: Row(
                  children: [
                    const Icon(Icons.rocket_launch_outlined, size: 15),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${l(context).bgTaskRunning} ($count)',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                    ),
                    Icon(
                      Icons.chevron_right,
                      size: 18,
                      color: theme.colorScheme.outline,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SubagentBody extends StatelessWidget {
  final String? childSessionId;
  final String parentSessionId;
  const _SubagentBody({
    required this.childSessionId,
    required this.parentSessionId,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final appColors = theme.extension<AppColors>()!;
    final loc = l(context);
    final sid = childSessionId;
    if (sid == null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
        child: Text(
          loc.subagentNoSession,
          style: TextStyle(fontSize: 12, color: theme.colorScheme.outline),
        ),
      );
    }
    final conv = serverStore.conversationForRead(sid);
    // 窗口背景由 Material 承担（Container 只留 border/clip）：InkWell 水墨
    // 画在 Material 子树之下（_RenderInkFeatures 先 ink 后 child），若不
    // 自带 Material，内嵌 chip 的水墨会落到 Scaffold 级 Material——页面
    // 内容透明处（窗口外/面板下方）可见，即「阴影逃出窗口」；若 Material
    // 带透明底放在 Container 的 color 之下，水墨又会被窗口背景完全盖住。
    // Material.color = 窗口背景 → 水墨落在背景之上、内容之下，且整体仍在
    // Container 的圆角 clip 内：可见且不越界。
    return Container(
      margin: const EdgeInsets.fromLTRB(0, 8, 0, 2),
      constraints: const BoxConstraints(maxHeight: 400),
      clipBehavior: Clip.hardEdge,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: appColors.border),
      ),
      child: Material(
        type: MaterialType.canvas,
        color: appColors.codeBackground,
        child: conv == null
            ? Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  loc.subagentLoading,
                  style: TextStyle(
                      fontSize: 12, color: theme.colorScheme.outline),
                ),
              )
            : ListenableBuilder(
                listenable: conv,
                builder: (context, _) {
                  final msgs = conv.renderableMessages;
                  if (msgs.isEmpty) {
                    // 已加载但无消息 = 子会话无输出；未加载才是「加载中」。
                    return Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        conv.loaded ? loc.subagentNoOutput : loc.subagentLoading,
                        style: TextStyle(
                            fontSize: 12, color: theme.colorScheme.outline),
                      ),
                    );
                  }
                  return _SubagentMessageList(
                    messages: msgs,
                    parentSessionId: parentSessionId,
                  );
                },
              ),
      ),
    );
  }
}

/// reverse ListView：offset 0 = 底部（最新），天然贴底跟随（与主列表同构）。
/// 滚动条隐藏对齐主消息流。itemExtent 无——条目高度不定。
class _SubagentMessageList extends StatelessWidget {
  final List<DisplayMessage> messages;
  final String parentSessionId;
  const _SubagentMessageList({
    required this.messages,
    required this.parentSessionId,
  });

  @override
  Widget build(BuildContext context) {
    return ScrollConfiguration(
      behavior: const _HiddenScrollbarBehavior(),
      child: ListView.builder(
        reverse: true,
        padding: const EdgeInsets.all(8),
        itemCount: messages.length,
        itemBuilder: (context, i) {
          final m = messages[i];
          return _SubagentMessage(
            key: ValueKey(m.id),
            message: m,
            parentSessionId: parentSessionId,
          );
        },
      ),
    );
  }
}

class _HiddenScrollbarBehavior extends ScrollBehavior {
  const _HiddenScrollbarBehavior();

  @override
  Widget buildScrollbar(
          BuildContext context, Widget child, ScrollableDetails details) =>
      child;
}

/// 子会话单条消息的轻量渲染：user → 左侧弱化文本；assistant → parts
/// （text 稳定 Markdown、tool → _ToolChip、reasoning → 灰字、subtask →
/// 标签行）。流式期间（finish==null）text 降级纯文本，与主列表 JANK-4
/// 同理——子面板条目少、降级渲染成本低，但保持一致避免逐 token 全量
/// 重解析。嵌套 task 工具渲染为 ToolChip（input/output 视图）——比桌面端
/// 依赖 server subagent_depth 更强的 UI 防护。
class _SubagentMessage extends StatefulWidget {
  final DisplayMessage message;
  final String parentSessionId;
  const _SubagentMessage({
    super.key,
    required this.message,
    required this.parentSessionId,
  });

  @override
  State<_SubagentMessage> createState() => _SubagentMessageState();
}

class _SubagentMessageState extends State<_SubagentMessage> {
  String? _linkifiedFor;
  String _linkified = '';
  final _partCache = _PartWidgetCache();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _partCache.clear();
  }

  /// autolink 记忆化：子会话流式期间 ListenableBuilder 每 part 事件重建，
  /// settled 消息的 text 不变——避免逐次全量重跑（主列表走 _autolinkCache
  /// 同理，面板内用 per-State 记忆化即可）。
  String _linkify(String data) {
    if (_linkifiedFor != data) {
      _linkifiedFor = data;
      _linkified = autolinkMarkdownLinks(data);
    }
    return _linkified;
  }

  void _onLink(BuildContext context, String? href) {
    if (href == null || href.isEmpty) return;
    if (href.startsWith('ob-file:///')) {
      final decoded = decodeFileHref(href);
      if (decoded == null) return;
      final (raw, line) = decoded;
      final directory =
          serverStore.sessionById(widget.parentSessionId)?.directory ?? '';
      final rel = resolveProjectPath(raw, directory);
      if (rel == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l(context).fileLinkNotInProject)),
        );
        return;
      }
      context.push(
        '/session/${widget.parentSessionId}/files'
        '?directory=${Uri.encodeQueryComponent(directory)}',
        extra: FileBrowsingSnapshot(
          openFiles: [
            OpenFileEntry(
              path: rel,
              scrollOffset: 0,
              wrap: false,
              showSource: line != null,
              initialLine: line,
            ),
          ],
          peek: true,
        ),
      );
      return;
    }
    openExternalLink(context, href);
  }

  String _errorText(Map<String, dynamic> error) {
    final data = error['data'];
    if (data is Map) {
      final msg = data['message']?.toString();
      if (msg != null && msg.isNotEmpty) return msg;
    } else if (data is String && data.isNotEmpty) {
      return data;
    }
    for (final key in ['message', 'error']) {
      final v = error[key]?.toString();
      if (v != null && v.isNotEmpty) return v;
    }
    return (error['name'] ?? 'Error').toString();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final appColors = theme.extension<AppColors>()!;
    final m = widget.message;
    final isUser = m.isUser;
    final streaming = !isUser && m.finish == null;
    final text = TextStyle(fontSize: 13, height: 1.45, color: appColors.code);

    final children = <Widget>[];
    if (m.error != null) {
      children.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(
            _errorText(m.error!),
            style: const TextStyle(
              fontSize: 12,
              color: Color(0xFFF85149),
            ),
          ),
        ),
      );
    }
    for (final p in m.parts) {
      switch (p.type) {
        case 'text':
          if (p.text.trim().isEmpty) break;
          if (streaming && !p.settled) {
            children.add(
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(p.text, style: text),
              ),
            );
          } else {
            final raw = p.text;
            final overLimit = raw.length > _kMarkdownMaxChars;
            final effective =
                overLimit ? _truncatedText(raw, _kMarkdownMaxChars) : raw;
            final cached = _partCache.lookup(p.id, effective);
            if (cached != null) {
              children.add(cached);
              break;
            }
            final mdBase = MarkdownStyleSheet.fromTheme(theme);
            final mdSheet = mdBase.copyWith(
              p: TextStyle(fontSize: 13, height: 1.45, color: appColors.code),
              h1: mdBase.h1?.copyWith(height: 1.45),
              h2: mdBase.h2?.copyWith(height: 1.45),
              h3: mdBase.h3?.copyWith(height: 1.45),
              h4: mdBase.h4?.copyWith(height: 1.45),
              h5: mdBase.h5?.copyWith(height: 1.45),
              h6: mdBase.h6?.copyWith(height: 1.45),
              code: TextStyle(
                  fontSize: 12,
                  fontFamily: 'monospace',
                  color: appColors.code),
            );
            final built = Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  MarkdownBody(
                    data: _linkify(effective),
                    softLineBreak: isUser,
                    onTapLink: (text, href, title) => _onLink(context, href),
                    styleSheet: mdSheet,
                  ),
                  if (overLimit)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        l(context).messageTruncated,
                        style: TextStyle(
                          fontSize: 11,
                          color: theme.colorScheme.outline,
                        ),
                      ),
                    ),
                ],
              ),
            );
            _partCache.store(p.id, effective, built);
            children.add(built);
          }
          break;
        case 'reasoning':
          if (!showThinking.value || p.text.trim().isEmpty) break;
          children.add(
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                p.text,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontStyle: FontStyle.italic,
                  color: theme.colorScheme.outline,
                  height: 1.45,
                ),
              ),
            ),
          );
          break;
        case 'tool':
          children.add(_ToolChip(part: p));
          break;
        case 'subtask':
          children.add(
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                p.text.isEmpty
                    ? 'subtask: ${p.command ?? 'subtask'}'
                    : 'subtask: ${p.command ?? 'subtask'}\n\n${p.text}',
                style: text.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
          );
          break;
        default:
          break;
      }
    }
    if (children.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: children,
      ),
    );
  }
}

const double imageBubbleMaxHeight = 220;

class _FileChip extends StatefulWidget {
  final DisplayPart part;
  final bool user;
  final bool isFirst;
  final String? sessionId;
  final String? directory;
  const _FileChip({
    super.key,
    required this.part,
    this.user = false,
    this.isFirst = false,
    this.sessionId,
    this.directory,
  });

  @override
  State<_FileChip> createState() => _FileChipState();
}

class _FileChipState extends State<_FileChip> {
  late final Future<Uint8List?> _bytes;

  DisplayPart get part => widget.part;
  bool get user => widget.user;
  bool get isFirst => widget.isFirst;
  String? get sessionId => widget.sessionId;
  String? get directory => widget.directory;

  bool get _isHttpUrl {
    final url = part.fileUrl;
    if (url == null) return false;
    return url.startsWith('http://') || url.startsWith('https://');
  }

  bool get _isReference => part.source?['type'] == 'file';
  String get _refPath =>
      part.source?['path']?.toString() ?? part.filename ?? '';

  bool get _isDisplayableImage =>
      (part.fileMime?.startsWith('image/') ?? false) &&
      part.fileMime != 'image/svg+xml' &&
      (part.fileUrl?.startsWith('data:') ?? false);

  @override
  void initState() {
    super.initState();
    final url = widget.part.fileUrl;
    _bytes = (url != null && url.startsWith('data:'))
        ? ImageDataCache.instance.get(url)
        : Future.value(null);
  }

  @override
  Widget build(BuildContext context) {
    final Widget content;
    if (_isReference) {
      content = _refChip(context);
    } else if (_isDisplayableImage) {
      content = _imageChip(context);
    } else {
      content = _filenameChip(context);
    }
    return isFirst
        ? content
        : Padding(padding: const EdgeInsets.only(top: 6), child: content);
  }

  Widget _refChip(BuildContext context) {
    final p = _messagePalette(context, user);
    final isDirRef = _refPath.endsWith('/');
    return GestureDetector(
      onTap: (isDirRef || sessionId == null)
          ? null
          : () => _openFileView(context),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isDirRef ? Icons.folder_outlined : Icons.insert_drive_file,
            size: 16,
            color: p.outline,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              _refPath,
              style: AppTheme.mono.copyWith(fontSize: 12, color: p.text),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _filenameChip(BuildContext context) {
    final p = _messagePalette(context, user);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.insert_drive_file, size: 16, color: p.outline),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            part.filename ?? part.fileUrl ?? l(context).attachmentFallback,
            style: AppTheme.mono.copyWith(fontSize: 12, color: p.text),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (_isHttpUrl) ...[
          const SizedBox(width: 6),
          GestureDetector(
            onTap: () => _openUrl(context),
            child: Icon(Icons.open_in_new, size: 14, color: p.link),
          ),
        ],
      ],
    );
  }

  Widget _imageChip(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: _bytes,
      builder: (ctx, snap) {
        final bytes = snap.data;
        if (bytes != null) {
          final dpr = MediaQuery.devicePixelRatioOf(ctx);
          return GestureDetector(
            onTap: () => _openFullScreen(ctx, bytes),
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxHeight: imageBubbleMaxHeight,
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.memory(
                  bytes,
                  cacheHeight: (imageBubbleMaxHeight * dpr).round(),
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => _filenameChip(ctx),
                ),
              ),
            ),
          );
        }
        if (snap.connectionState == ConnectionState.done) {
          return _filenameChip(ctx);
        }
        final thumb = part.previewThumb;
        if (thumb != null) return _placeholderThumb(ctx, thumb);
        return _decodingPlaceholder(ctx);
      },
    );
  }

  Widget _placeholderThumb(BuildContext context, Uint8List thumb) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.memory(thumb, width: 120, height: 120, fit: BoxFit.cover),
    );
  }

  Widget _decodingPlaceholder(BuildContext context) {
    return Container(
      width: 120,
      height: 120,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
    );
  }

  void _openFullScreen(BuildContext context, Uint8List bytes) {
    Navigator.of(context).push(
      slideLeftRoute(
        Scaffold(
          backgroundColor: Colors.black87,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            leading: IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
          body: SafeArea(child: ImageView(bytes: bytes, isSvg: false)),
        ),
      ),
    );
  }

  // CR-5：launchUrl 失败提示 + try/catch
  Future<void> _openUrl(BuildContext context) async {
    final url = part.fileUrl;
    if (url == null) return;
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      final ok = await launchUrl(uri);
      if (!ok && context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l(context).linkOpenFailed)));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l(context).linkOpenFailedDetail(e.toString())),
          ),
        );
      }
    }
  }

  void _openFileView(BuildContext context) {
    final sid = sessionId;
    if (sid == null) return;
    final path = _refPath;
    if (path.isEmpty) return;
    Navigator.of(context).push(
      slideLeftRoute(
        FileViewScreen(sessionId: sid, path: path, directory: directory),
      ),
    );
  }
}

class _FilePreviewBar extends StatelessWidget {
  final List<_PendingItem> pending;
  final ValueChanged<int> onRemove;
  const _FilePreviewBar({required this.pending, required this.onRemove});

  Widget _iconTile(BuildContext context, IconData icon) {
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(icon, size: 20),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 60,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        itemCount: pending.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (ctx, i) {
          final item = pending[i];
          final tile = switch (item) {
            _PendingAttachment(:final preview) =>
              preview.isImage && preview.previewThumb != null
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.memory(
                        preview.previewThumb!,
                        width: 48,
                        height: 48,
                        fit: BoxFit.cover,
                      ),
                    )
                  : _iconTile(context, Icons.insert_drive_file),
            _PendingFileRef(:final ref) => _iconTile(
              context,
              ref.isDir ? Icons.folder_outlined : Icons.insert_drive_file,
            ),
          };
          return Stack(
            clipBehavior: Clip.none,
            children: [
              tile,
              Positioned(
                right: -2,
                top: -2,
                child: GestureDetector(
                  onTap: () => onRemove(i),
                  child: Container(
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      shape: BoxShape.circle,
                    ),
                    padding: const EdgeInsets.all(2),
                    child: const Icon(Icons.close, size: 14),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _PermissionCard extends StatefulWidget {
  final Permission permission;
  final ConversationStore store;
  final int queueTotal;
  const _PermissionCard({
    super.key,
    required this.permission,
    required this.store,
    this.queueTotal = 1,
  });

  @override
  State<_PermissionCard> createState() => _PermissionCardState();
}

class _PermissionCardState extends State<_PermissionCard> {
  bool _replying = false;
  bool _collapsed = false;

  String _title(AppLocalizations loc) =>
      permissionTitle(loc, widget.permission);

  Future<void> _respond(String response) async {
    setState(() => _replying = true);
    try {
      await widget.store.respondPermission(widget.permission, response);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              l(context).replyFailed(friendlyMessage(l(context), e)),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _replying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = l(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primaryContainer.withAlpha(120),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Theme.of(context).colorScheme.primary.withAlpha(120),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _collapsed = !_collapsed),
            child: Row(
              children: [
                Icon(
                  Icons.shield_outlined,
                  size: 16,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 6),
                Text(
                  loc.permissionRequest,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                if (widget.queueTotal > 1)
                  Text(
                    loc.queuePending(1, widget.queueTotal),
                    style: TextStyle(
                      fontSize: 11.5,
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ),
                const SizedBox(width: 6),
                Icon(
                  _collapsed ? Icons.expand_less : Icons.expand_more,
                  size: 18,
                  color: Theme.of(context).colorScheme.outline,
                ),
              ],
            ),
          ),
          if (_collapsed)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _title(loc),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTheme.mono.copyWith(fontSize: 12.5),
              ),
            )
          else
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight:
                    MediaQuery.sizeOf(context).height *
                    _kFooterCardContentHeightFactor,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 8),
                    Text(
                      _title(loc),
                      style: AppTheme.mono.copyWith(fontSize: 12.5),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        FilledButton.tonal(
                          style: FilledButton.styleFrom(
                            foregroundColor: Colors.red,
                            backgroundColor: Colors.red.withAlpha(25),
                          ),
                          onPressed: _replying
                              ? null
                              : () => _respond('reject'),
                          child: Text(loc.reject),
                        ),
                        const SizedBox(width: 8),
                        FilledButton.tonal(
                          onPressed: _replying
                              ? null
                              : () => _respond('always'),
                          child: Text(loc.permissionAlwaysAllow),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: _replying ? null : () => _respond('once'),
                          child: _replying
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Text(loc.permissionAllowOnce),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _FormCard extends StatefulWidget {
  final FormInfo form;
  final ConversationStore store;
  final int queueTotal;
  const _FormCard({
    super.key,
    required this.form,
    required this.store,
    this.queueTotal = 1,
  });

  @override
  State<_FormCard> createState() => _FormCardState();
}

class _FormCardState extends State<_FormCard> {
  final Map<String, Set<String>> _selected = {};
  final Map<String, TextEditingController> _textCtl = {};
  bool _replying = false;
  int _step = 0;
  bool _collapsed = false;

  List<FormFieldSpec> get _fields => widget.form.fields;

  FormFieldSpec get _field => _fields[_step];

  void _toggle(String key, String value, bool multiselect) {
    setState(() {
      final sel = _selected.putIfAbsent(key, () => {});
      if (sel.contains(value)) {
        sel.remove(value);
      } else {
        if (!multiselect) sel.clear();
        sel.add(value);
      }
    });
  }

  TextEditingController _ctlFor(String key) =>
      _textCtl.putIfAbsent(key, TextEditingController.new);

  TextEditingController _customCtlFor(String key) =>
      _textCtl.putIfAbsent('$key\u0000custom', TextEditingController.new);

  bool _hasOptions(FormFieldSpec f) =>
      (f.type == 'string' || f.type == 'multiselect') && f.options.isNotEmpty;

  String _customText(FormFieldSpec f) =>
      f.custom && _hasOptions(f) ? _customCtlFor(f.key).text.trim() : '';

  Map<String, dynamic> _buildAnswer() {
    final answer = <String, dynamic>{};
    for (final f in _fields) {
      final sel = _selected[f.key] ?? const <String>{};
      final useCustom = sel.contains(_kCustomOptionValue);
      if (f.type == 'multiselect') {
        final values = sel.where((v) => v != _kCustomOptionValue).toList();
        final custom = useCustom ? _customText(f) : '';
        answer[f.key] = custom.isEmpty ? values : [...values, custom];
      } else if (f.type == 'string' && f.options.isNotEmpty) {
        if (useCustom) {
          answer[f.key] = _customText(f);
        } else {
          final values = sel.where((v) => v != _kCustomOptionValue).toList();
          answer[f.key] = values.isEmpty ? '' : values.first;
        }
      } else if (f.type == 'boolean') {
        answer[f.key] = sel.isNotEmpty;
      } else if (f.type == 'integer' || f.type == 'number') {
        final t = _ctlFor(f.key).text.trim();
        answer[f.key] =
            f.type == 'integer' ? (int.tryParse(t) ?? 0) : (double.tryParse(t) ?? 0);
      } else {
        answer[f.key] = _ctlFor(f.key).text;
      }
    }
    return answer;
  }

  Future<void> _reply() async {
    setState(() => _replying = true);
    try {
      await widget.store.replyForm(widget.form, _buildAnswer());
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              l(context).replyFailed(friendlyMessage(l(context), e)),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _replying = false);
    }
  }

  Future<void> _reject() async {
    setState(() => _replying = true);
    try {
      await widget.store.cancelForm(widget.form);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              l(context).replyFailed(friendlyMessage(l(context), e)),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _replying = false);
    }
  }

  bool get _stepAnswered {
    final f = _field;
    final sel = _selected[f.key] ?? const <String>{};
    if (f.type == 'multiselect' || (f.type == 'string' && f.options.isNotEmpty)) {
      if (sel.isEmpty) return false;
      if (sel.contains(_kCustomOptionValue)) return _customText(f).isNotEmpty;
      return true;
    }
    if (f.type == 'boolean') {
      return _selected.containsKey(f.key);
    }
    return _ctlFor(f.key).text.trim().isNotEmpty;
  }

  bool get _isLastStep => _step >= _fields.length - 1;

  void _next() {
    if (_stepAnswered && !_isLastStep) {
      setState(() => _step++);
    }
  }

  @override
  void dispose() {
    for (final ctl in _textCtl.values) {
      ctl.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final totalSub = _fields.length;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer.withAlpha(100),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.tertiary.withAlpha(120)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _collapsed = !_collapsed),
            child: Row(
              children: [
                Icon(Icons.help_outline, size: 16, color: scheme.tertiary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    widget.form.title,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (totalSub > 1)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Text(
                      '${_step + 1}/$totalSub',
                      style: TextStyle(fontSize: 11.5, color: scheme.outline),
                    ),
                  ),
                if (widget.queueTotal > 1)
                  Text(
                    l(context).queuePending(1, widget.queueTotal),
                    style: TextStyle(fontSize: 11.5, color: scheme.outline),
                  ),
                const SizedBox(width: 6),
                Icon(
                  _collapsed ? Icons.expand_less : Icons.expand_more,
                  size: 18,
                  color: scheme.outline,
                ),
              ],
            ),
          ),
          if (!_collapsed)
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight:
                    MediaQuery.sizeOf(context).height *
                    _kFooterCardContentHeightFactor,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _fieldBlock(_field),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        const Spacer(),
                        FilledButton.tonal(
                          style: FilledButton.styleFrom(
                            foregroundColor: Colors.red,
                            backgroundColor: Colors.red.withAlpha(25),
                          ),
                          onPressed: _replying ? null : _reject,
                          child: Text(l(context).reject),
                        ),
                        const SizedBox(width: 8),
                        if (_isLastStep)
                          FilledButton(
                            onPressed: _replying || !_stepAnswered
                                ? null
                                : _reply,
                            child: _replying
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : Text(l(context).submit),
                          )
                        else
                          FilledButton(
                            onPressed: _replying || !_stepAnswered
                                ? null
                                : _next,
                            child: Text(l(context).nextStep),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _fieldBlock(FormFieldSpec f) {
    final scheme = Theme.of(context).colorScheme;
    final sel = _selected[f.key] ?? const <String>{};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 6),
        if ((f.title ?? f.description ?? '').isNotEmpty)
          Text(
            f.title ?? f.description ?? '',
            style: TextStyle(
              fontSize: 13,
              color: scheme.onSurface,
            ),
          ),
        if ((f.description ?? '').isNotEmpty && (f.title ?? '').isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              f.description!,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: scheme.outline),
            ),
          ),
        const SizedBox(height: 8),
        if (_hasOptions(f)) ...[
          for (final opt in f.options)
            _optionTile(
              f: f,
              value: opt.value,
              label: opt.label,
              description: opt.description,
            ),
          if (f.custom) ...[
            _optionTile(
              f: f,
              value: _kCustomOptionValue,
              label: l(context).formCustomAnswer,
            ),
            if (sel.contains(_kCustomOptionValue))
              Padding(
                padding: const EdgeInsets.only(left: 26, bottom: 4),
                child: _customAnswerField(f),
              ),
          ],
        ] else if (f.type == 'boolean')
          InkWell(
            onTap: _replying ? null : () => _toggle(f.key, 'true', true),
            borderRadius: BorderRadius.circular(8),
            child: Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 4),
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: sel.isNotEmpty
                    ? scheme.tertiary.withAlpha(60)
                    : scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: sel.isNotEmpty ? scheme.tertiary : Colors.transparent,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    sel.isNotEmpty
                        ? Icons.check_box
                        : Icons.check_box_outline_blank,
                    size: 18,
                    color: scheme.tertiary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      f.title ?? f.key,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          )
        else
          TextField(
            controller: _ctlFor(f.key),
            enabled: !_replying,
            onChanged: (_) => setState(() {}),
            keyboardType: f.type == 'integer' || f.type == 'number'
                ? TextInputType.number
                : TextInputType.text,
            maxLines: f.type == 'string' ? 3 : 1,
            decoration: InputDecoration(
              hintText: f.placeholder ?? '',
              isDense: true,
              border: const OutlineInputBorder(),
            ),
          ),
      ],
    );
  }

  Widget _optionTile({
    required FormFieldSpec f,
    required String value,
    required String label,
    String? description,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final active = (_selected[f.key] ?? const <String>{}).contains(value);
    return InkWell(
      onTap: _replying ? null : () => _toggle(f.key, value, f.isMultiselect),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: active
              ? scheme.tertiary.withAlpha(60)
              : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: active ? scheme.tertiary : Colors.transparent,
          ),
        ),
        child: Row(
          children: [
            Icon(
              active
                  ? (f.isMultiselect
                        ? Icons.check_box
                        : Icons.radio_button_checked)
                  : (f.isMultiselect
                        ? Icons.check_box_outline_blank
                        : Icons.radio_button_unchecked),
              size: 18,
              color: scheme.tertiary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                  if ((description ?? '').isNotEmpty)
                    Text(
                      description!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.outline,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _customAnswerField(FormFieldSpec f) {
    return TextField(
      controller: _customCtlFor(f.key),
      enabled: !_replying,
      onChanged: (_) => setState(() {}),
      maxLines: 1,
      decoration: InputDecoration(
        hintText: f.placeholder ?? '',
        isDense: true,
        border: const OutlineInputBorder(),
      ),
    );
  }
}

class _TypingDots extends StatelessWidget {
  const _TypingDots();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        children: List.generate(
          3,
          (i) => Padding(
            padding: const EdgeInsets.only(right: 4),
            child: _Dot(delay: i * 300),
          ),
        ),
      ),
    );
  }
}

/// Retry indicator shown in the message stream (replaces _TypingDots during
/// retry). Styled like an assistant message bubble, with an animated spinning
/// refresh icon to convey the retry action is in progress.
class _RetryMessage extends StatelessWidget {
  final String message;
  const _RetryMessage({required this.message});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 24, top: 10, bottom: 10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFFFB923C).withAlpha(20),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFFFB923C).withAlpha(80)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SpinningRefresh(),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                l(context).retryingMessage(message),
                style: const TextStyle(
                  fontSize: 14,
                  height: 1.45,
                  color: Color(0xFFFB923C),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown when a refresh proved the session's worktree directory no longer
/// exists (ghost worktree). Same bubble style as `_RetryMessage`, error-colored
/// with a static warning icon — nothing is retrying; the session is unusable.
class _WorkspaceMissingBanner extends StatelessWidget {
  const _WorkspaceMissingBanner();

  @override
  Widget build(BuildContext context) {
    final error = Theme.of(context).colorScheme.error;
    return Padding(
      padding: const EdgeInsets.only(right: 24, top: 10, bottom: 10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: error.withAlpha(20),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: error.withAlpha(80)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(Icons.warning_amber_rounded, size: 18, color: error),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                l(context).workspaceMissing,
                style: TextStyle(fontSize: 14, height: 1.45, color: error),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Continuously-rotating refresh icon. Conveys "retry in progress" motion.
class _SpinningRefresh extends StatefulWidget {
  const _SpinningRefresh();

  @override
  State<_SpinningRefresh> createState() => _SpinningRefreshState();
}

class _SpinningRefreshState extends State<_SpinningRefresh>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RotationTransition(
      turns: _c,
      child: const Icon(Icons.refresh, size: 16, color: Color(0xFFFB923C)),
    );
  }
}

/// Loading indicator shown at the visual top of the message list while
/// fetching an older page (scroll-up lazy pagination).
class _LoadingEarlierRow extends StatelessWidget {
  const _LoadingEarlierRow();

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2, color: color),
            ),
            const SizedBox(width: 8),
            Text(
              l(context).loadingMore,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w400,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Footer hint shown while a stale session is gated: reconcile in flight,
/// live SSE tail stays visible (GL-1 gap gate).
class _SyncingRow extends StatelessWidget {
  const _SyncingRow();

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 1.5, color: color),
            ),
            const SizedBox(width: 8),
            Text(
              l(context).syncingMessages,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w300,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// In-stream divider rendered at the gate baseline while gated: marks that
/// messages between the cached base and the live tail may still be syncing
/// (GL-1). Disappears in the same frame the gate ends.
class _GapSyncDivider extends StatelessWidget {
  const _GapSyncDivider();

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.outline;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 1.5, color: color),
            ),
            const SizedBox(width: 8),
            Text(
              l(context).gapSyncing,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w300,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Error hint shown at the visual top when a backward page load failed
/// (IR-R4). Tapping or scrolling retries (scrolling triggers _onScroll →
/// _maybeLoadEarlier; loadOnePage clears the error flag on entry).
class _LoadEarlierErrorRow extends StatelessWidget {
  final VoidCallback? onRetry;
  const _LoadEarlierErrorRow({this.onRetry});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onRetry,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Center(
          child: Text(
            l(context).loadEarlierFailedHint,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w400,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

class _Dot extends StatefulWidget {
  final int delay;
  const _Dot({required this.delay});

  @override
  State<_Dot> createState() => _DotState();
}

class _DotState extends State<_Dot> with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    Future.delayed(Duration(milliseconds: widget.delay), () {
      if (mounted) _c.repeat(reverse: true);
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) {
        final a = 0.3 + 0.7 * _c.value;
        return Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: Theme.of(
              context,
            ).colorScheme.primary.withAlpha((255 * a).round()),
            shape: BoxShape.circle,
          ),
        );
      },
    );
  }
}

/// Applies the software-keyboard inset as bottom padding in place of
/// `Scaffold.resizeToAvoidBottomInset` (which is disabled on the conversation
/// Scaffold). A `resizeToAvoidBottomInset:true` Scaffold registers a dependency
/// on `MediaQuery` viewInsets, so during the keyboard animation it (and every
/// offstage conversation route left mounted in the navigator) rebuilds each
/// frame. Here only this small widget depends on viewInsets; its [child] is the
/// same widget instance across animation frames, so the subtree is pruned by
/// identity and only this padding rebuilds.
class _KeyboardAvoider extends StatelessWidget {
  final Widget child;
  const _KeyboardAvoider({required this.child});

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: child,
    );
  }
}

class _KeepAliveMessage extends StatefulWidget {
  final String msgId;
  final ValueNotifier<Set<String>> keepAliveIds;
  final Widget child;
  const _KeepAliveMessage({
    super.key,
    required this.msgId,
    required this.keepAliveIds,
    required this.child,
  });

  @override
  State<_KeepAliveMessage> createState() => _KeepAliveMessageState();
}

class _KeepAliveMessageState extends State<_KeepAliveMessage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => widget.keepAliveIds.value.contains(widget.msgId);

  @override
  void initState() {
    super.initState();
    widget.keepAliveIds.addListener(_onKeepAliveIdsChanged);
  }

  @override
  void didUpdateWidget(covariant _KeepAliveMessage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.keepAliveIds != widget.keepAliveIds) {
      oldWidget.keepAliveIds.removeListener(_onKeepAliveIdsChanged);
      widget.keepAliveIds.addListener(_onKeepAliveIdsChanged);
    }
  }

  void _onKeepAliveIdsChanged() => updateKeepAlive();

  @override
  void dispose() {
    widget.keepAliveIds.removeListener(_onKeepAliveIdsChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

class _BackToTurnTopButton extends StatelessWidget {
  final ValueNotifier<double?> target;
  final void Function(double) onTap;
  const _BackToTurnTopButton({required this.target, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double?>(
      valueListenable: target,
      builder: (context, t, _) {
        final visible = t != null;
        return IgnorePointer(
          ignoring: !visible,
          child: AnimatedOpacity(
            opacity: visible ? 1 : 0,
            duration: const Duration(milliseconds: 150),
            child: AnimatedScale(
              scale: visible ? 1 : 0.8,
              duration: const Duration(milliseconds: 150),
              child: Material(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                shape: CircleBorder(
                  side: BorderSide(
                    color: Theme.of(context).colorScheme.outline,
                  ),
                ),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: visible ? () => onTap(t) : null,
                  child: const SizedBox(
                    width: 36,
                    height: 36,
                    child: Icon(Icons.vertical_align_top, size: 18),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 高用户消息折叠壳（在 _messageChildCache 之外：展开/收起只重建壳层，内容
/// 子树走实例等值剪枝）。壳挂在气泡级（消息 Padding/Align 之内），裁剪宽度
/// 即气泡宽：折叠裁切用与气泡同半径的底圆角 ClipRRect，收起后仍是圆角矩形。
/// 自然高度（整条消息，含外层垂直 padding）未跨过门槛时原样透传；跨过后
/// 默认折叠——气泡 clamp 到整屏高 × [_kUserCollapseFraction]（MediaQuery.size，
/// 键盘无关）。切换带高度动画，动画期间按帧增量校正反向列表滚动（气泡顶部
/// 视觉锚定，复刻 _ToolChip 的 _syncReversedScroll 思路）。折叠渲染用
/// _TopClampBox 让内容按自然尺寸布局，被裁部分不参与命中测试。
///
/// 手势（三期：收起/展开行为一致）：正文保持完全可交互——链接可点、长按
/// 选词复制、代码块/表格横向滚动；短按任意位置切换折叠/展开：
/// - 文本区 tap 被 selectable markdown 的内部手势赢走（光标/选区副作用由
///   [ExcludeFocus] 收口，不抢输入框焦点），壳层经 MarkdownBody.onTapText
///   观察该 tap 并切换；链接 tap 由 span recognizer 赢出、不触发 onTapText，
///   天然分流不折叠。
/// - 空白区/渐变条/浮标 tap 无内部竞争者，壳层 GestureDetector 直接赢出。
/// - 长按由 SelectableText 内部 LongPress 赢出（选词 + 工具栏），两态一致。
/// - 代码块/表格正文上的横向拖动会被 SelectableText 的 TapAndHorizontalDrag
///   赢走（无焦点时触摸端纯 no-op），[_HScrollForwarder] 以裸 Listener 旁路
///   手势竞技场，把横向拖动转发给内部横向 Scrollable，实现横向滚动。
/// 折叠态不再 IgnorePointer 正文（一期做法），被裁部分由 _TopClampBox 的
/// 盒子尺寸挡在命中测试外。
class _UserCollapseHost extends StatefulWidget {
  final double? naturalHeight;
  final bool expanded;
  final VoidCallback onToggle;
  final ValueChanged<bool> onAnimating;
  final Widget child;

  const _UserCollapseHost({
    super.key,
    required this.naturalHeight,
    required this.expanded,
    required this.onToggle,
    required this.onAnimating,
    required this.child,
  });

  @override
  State<_UserCollapseHost> createState() => _UserCollapseHostState();
}

class _UserCollapseHostState extends State<_UserCollapseHost>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: _kUserCollapseAnimDuration,
  );
  late final Animation<double> _curved = _ctrl.drive(
    CurveTween(curve: Curves.easeInOutCubic),
  );
  double _lastV = 0;
  double _collapseHeight = 0;

  @override
  void initState() {
    super.initState();
    _curved.addListener(_onTick);
    _curved.addStatusListener(_onStatus);
    _lastV = widget.expanded ? 1 : 0;
    _ctrl.value = _lastV;
  }

  @override
  void didUpdateWidget(_UserCollapseHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.expanded != widget.expanded) {
      widget.onAnimating(true);
      _ctrl.animateTo(widget.expanded ? 1 : 0);
    }
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed ||
        status == AnimationStatus.dismissed) {
      widget.onAnimating(false);
    }
  }

  /// 反向列表中条目增高的偏移锚在底缘：不做校正时内容顶端会向上飞出视口。
  /// 校正量按自身实测几何算：本帧增量先被「壳顶距视口顶的剩余上升空间」
  /// 自然吸收，余量才滚动补偿——展开时气泡顶部视觉锚定、向下展开，收起
  /// 时向上折回（与 _ToolChip 的 _syncReversedScroll 同一意图）。展开方向
  /// 按构造不越上界（tick 先于本帧布局，maxScrollExtent 滞后一帧，不能
  /// clamp 上界否则校正被逐帧吃掉、锚定失效）；收起方向显式 clamp 下界
  /// ——展开锚定把壳顶钉在视口顶（top ≥ 0），全额回撤会在内容不足视口
  /// （maxScrollExtent=0）时把 pixels 打到负值，与视口 overscroll 物理逐帧
  /// 打架。pixels 触 0 后内容已贴底，让壳顶随收缩自然下沉即是正确视觉。
  /// _collapseHeight 在 build 中刷新，动画期间属性稳定。
  void _onTick() {
    final v = _curved.value;
    final dv = v - _lastV;
    _lastV = v;
    final n = widget.naturalHeight;
    if (dv == 0 || n == null || _collapseHeight <= 0) return;
    final span = (n - _kUserMsgVerticalPadding * 2 + _kUserExpandBottomInset) -
        _collapseHeight;
    if (span <= 0) return;
    final ro = context.findRenderObject();
    final vp = ro == null ? null : RenderAbstractViewport.maybeOf(ro);
    if (ro is! RenderBox || vp is! RenderBox || !ro.attached) return;
    final pos = context.findAncestorStateOfType<ScrollableState>()?.position;
    if (pos == null || !pos.hasContentDimensions) return;
    final top = ro.localToGlobal(Offset.zero, ancestor: vp).dy;
    final corr = dv > 0
        ? math.max(0.0, span * dv - math.max(0.0, top))
        : math.min(0.0, span * dv + math.max(0.0, -top));
    if (corr == 0) return;
    // 只 clamp 下界：tick 先于本帧布局，maxScrollExtent 还是上一帧的值，
    // 展开校正按构造 ≤ 布局后的新 max——clamp 上界会把校正逐帧吃掉、
    // 锚定失效（气泡整体上飘）。
    final target = math.max(pos.pixels + corr, pos.minScrollExtent);
    if (target == pos.pixels) return;
    pos.correctPixels(target);
  }

  @override
  void dispose() {
    if (_ctrl.isAnimating) widget.onAnimating(false);
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.naturalHeight;
    final collapseHeight =
        MediaQuery.sizeOf(context).height * _kUserCollapseFraction;
    _collapseHeight = collapseHeight;
    if (n == null || n <= collapseHeight + _kUserCollapseMinGain) {
      return _HScrollForwarder(
        child: ExcludeFocus(child: widget.child),
      );
    }
    return _HScrollForwarder(
      child: AnimatedBuilder(
        animation: _curved,
        builder: (context, _) {
          final t = _curved.value;
          if (t >= 1) return _expandedBubble(context);
          final h = collapseHeight +
              (n - _kUserMsgVerticalPadding * 2 +
                      _kUserExpandBottomInset -
                      collapseHeight) *
                  t;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onToggle,
            child: Stack(
              children: [
                ClipRRect(
                  borderRadius: const BorderRadius.vertical(
                    bottom: Radius.circular(14),
                  ),
                  // 折叠态正文保持可交互（链接/长按复制/代码横滚，与展开态
                  // 一致）；文本区 tap 经 onTapText 切换展开。被裁部分由
                  // _TopClampBox 的盒子尺寸挡在命中测试外。child 包
                  // _UserExpandBase（自然高度含底部留白）：_TopClampBox 的
                  // clamp 上限与动画目标同为「气泡自然高 + 留白」，动画末端
                  // 高度逐帧连续，切 t>=1 展开分支无 +44 单帧跳变。
                  child: _TopClampBox(
                    height: h,
                    child: ExcludeFocus(
                      child: _UserExpandBase(child: widget.child),
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Opacity(
                    opacity: 1 - t,
                    child: const _UserCollapseFade(icon: Icons.expand_more),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// 展开态：与过渡动画帧共用 [_UserExpandBase] 基底（气泡 + 同色同半径外壳
  /// 向下延伸的底部留白，视觉即气泡变高一截，无接缝无额外描边），留白承载
  /// 底部渐变遮罩 + 无背景收起指示——与收起态样式一致，且遮罩/指示恰居中于
  /// 正文以下空白，不遮挡内容（内容增高仍可自发产生尺寸通知）。留白计入
  /// 渲染高度，动画目标按自然高度 + 留白换算（见 [_kUserExpandBottomInset]
  /// 口径）。短按任意位置收起：空白/指示 tap 由壳层 GestureDetector 赢出，
  /// 文本区 tap 经 onTapText 观察切换，链接 tap 分流不收起。
  Widget _expandedBubble(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onToggle,
      child: Stack(
        children: [
          ExcludeFocus(child: _UserExpandBase(child: widget.child)),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            // 遮罩/指示自带 IgnorePointer：末行居中的链接（用户消息尾部贴
            // URL/路径常见）tap 穿透到链接 recognizer，空白处仍由壳层
            // GestureDetector 收起。
            child: _UserCollapseFade(icon: Icons.expand_less),
          ),
        ],
      ),
    );
  }
}

/// 用户气泡内的横向滚动转发器：代码块/表格正文上的横向拖动会被
/// SelectableText 的 TapAndHorizontalDragGestureRecognizer 赢走（气泡内正文
/// 被 [ExcludeFocus] 收口后，触摸端该赢家是纯 no-op），内部的横向
/// SingleChildScrollView 拿不到拖动。此 widget 以裸 [Listener] 旁路手势
/// 竞技场（raw 事件路由不受竞技场胜负影响），在指针按下时命中测试找出
/// 指针下的横向 [Scrollable]，横向位移超过 slop 且横向主导时，用
/// [ScrollPosition.drag] 把后续位移转发给它（带速度跟踪，抬手给 fling）。
/// 纵向拖动不转发（列表滚动不受影响）；tap/长按/链接点按走原手势系统。
class _HScrollForwarder extends StatefulWidget {
  final Widget child;

  const _HScrollForwarder({required this.child});

  @override
  State<_HScrollForwarder> createState() => _HScrollForwarderState();
}

class _HScrollForwarderState extends State<_HScrollForwarder> {
  int? _pointer;
  Offset _down = Offset.zero;
  ScrollableState? _target;
  Drag? _drag;
  VelocityTracker? _tracker;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _onDown,
      onPointerMove: _onMove,
      onPointerUp: _onUp,
      onPointerCancel: _onCancel,
      child: widget.child,
    );
  }

  void _onDown(PointerDownEvent e) {
    if (_pointer != null) return;
    _pointer = e.pointer;
    _down = e.position;
    _tracker = VelocityTracker.withKind(e.kind)
      ..addPosition(e.timeStamp, e.position);
    _target = _findHorizontalScrollable(e.position);
  }

  void _onMove(PointerMoveEvent e) {
    if (e.pointer != _pointer) return;
    _tracker?.addPosition(e.timeStamp, e.position);
    final target = _target;
    if (target == null || !target.mounted) return;
    final d = e.position - _down;
    if (_drag == null) {
      // 与内部 TapAndHorizontalDrag 同一门槛（kTouchSlop）判定横向拖动；
      // 横向主导才接管，纵向留给会话列表滚动。
      if (d.dx.abs() <= kTouchSlop || d.dx.abs() <= d.dy.abs()) return;
      _drag = target.position.drag(
        DragStartDetails(
          globalPosition: _down,
          sourceTimeStamp: e.timeStamp,
        ),
        () => _drag = null,
      );
    } else if (d.dy.abs() > d.dx.abs()) {
      // 接管后手势转为纵向主导：中止转发，避免与列表纵向滚动叠加出双滚动
      // （代码块 padding 带起手、iOS 文本区斜拖——这两处竞技场无人预先
      // 拒绝列表的 VerticalDrag）。本指针剩余生命周期不再接管。
      _drag?.cancel();
      _reset();
      return;
    }
    _drag?.update(
      DragUpdateDetails(
        globalPosition: e.position,
        delta: Offset(e.delta.dx, 0),
        primaryDelta: e.delta.dx,
        sourceTimeStamp: e.timeStamp,
      ),
    );
  }

  void _onUp(PointerUpEvent e) {
    if (e.pointer != _pointer) return;
    final drag = _drag;
    final target = _target;
    if (drag != null && target != null && target.mounted) {
      final v = _tracker?.getVelocity() ?? Velocity.zero;
      drag.end(
        DragEndDetails(velocity: v, primaryVelocity: v.pixelsPerSecond.dx),
      );
    }
    _reset();
  }

  void _onCancel(PointerCancelEvent e) {
    if (e.pointer != _pointer) return;
    _drag?.cancel();
    _reset();
  }

  void _reset() {
    _pointer = null;
    _target = null;
    _drag = null;
    _tracker = null;
  }

  /// 命中测试找出指针下最深的可滚动横向 [Scrollable]（代码块/表格的
  /// SingleChildScrollView）。只认命中路径上的——折叠态裁切线以下、渐变
  /// 覆盖区内的横向滚动区域不会被误转发。
  ScrollableState? _findHorizontalScrollable(Offset global) {
    final rb = context.findRenderObject();
    if (rb is! RenderBox || !rb.hasSize) return null;
    final result = HitTestResult();
    rb.hitTest(
      BoxHitTestResult.wrap(result),
      position: rb.globalToLocal(global),
    );
    final hit = <RenderObject>{};
    for (final entry in result.path) {
      final t = entry.target;
      if (t is RenderObject) hit.add(t);
    }
    ScrollableState? found;
    void visit(Element el) {
      final w = el.widget;
      if (w is Scrollable && w.axis == Axis.horizontal && el is StatefulElement) {
        final state = el.state;
        if (state is ScrollableState && state.mounted) {
          final srb = state.context.findRenderObject();
          final pos = state.position;
          if (srb != null &&
              hit.contains(srb) &&
              pos.hasContentDimensions &&
              pos.maxScrollExtent > 0) {
            found = state;
          }
        }
      }
      el.visitChildElements(visit);
    }

    (context as Element).visitChildElements(visit);
    return found;
  }
}

/// 折叠/过渡态的裁剪盒：child 按自然尺寸布局（高度不受限），盒子宽度贴
/// child（shrink-wrap），高度 clamp 到给定值、child 顶对齐。替代
/// SizedBox+OverflowBox——OverflowBox 默认 fit: OverflowBoxFit.max 会把
/// 盒子撑到父级最大宽（气泡级壳会变 736 宽而非气泡宽 320）。
class _TopClampBox extends SingleChildRenderObjectWidget {
  final double height;

  const _TopClampBox({required this.height, super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderTopClampBox(height);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderTopClampBox renderObject,
  ) {
    renderObject.height = height;
  }
}

class _RenderTopClampBox extends RenderShiftedBox {
  _RenderTopClampBox(this._height) : super(null);

  double _height;

  set height(double value) {
    if (_height == value) return;
    _height = value;
    markNeedsLayout();
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final child = this.child;
    if (child == null) return constraints.smallest;
    final childSize = child.getDryLayout(
      constraints.copyWith(minHeight: 0, maxHeight: double.infinity),
    );
    return constraints.constrain(
      Size(childSize.width, _height.clamp(0.0, childSize.height)),
    );
  }

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(
      constraints.copyWith(minHeight: 0, maxHeight: double.infinity),
      parentUsesSize: true,
    );
    size = constraints.constrain(
      Size(child.size.width, _height.clamp(0.0, child.size.height)),
    );
    (child.parentData! as BoxParentData).offset = Offset.zero;
  }
}

/// 展开基底：气泡 + 同色（userBubble）同半径（14）外壳向下延伸的底部留白
/// （[_kUserExpandBottomInset]），展开态与过渡动画帧共用——动画分支的
/// _TopClampBox child 自然高度因此含留白，clamp 上限与动画目标（气泡
/// 自然高 + 留白）一致，切换两分支高度连续无跳变。折叠态该留白位于裁切线
/// 以下不可见；外壳与气泡同色叠印，无接缝无额外描边。
class _UserExpandBase extends StatelessWidget {
  final Widget child;

  const _UserExpandBase({required this.child});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AppColors>()!;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.userBubble,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Padding(
        padding: const EdgeInsets.only(bottom: _kUserExpandBottomInset),
        child: child,
      ),
    );
  }
}

/// 折叠/展开态共用的底部渐变遮罩 + 方向指示（纯视觉，自带 IgnorePointer 不
/// 参与命中测试；宽度即气泡宽——壳挂在气泡级，无需再复刻 left 40 /
/// maxWidth 320 几何）。展开态遮罩落在外壳延伸的留白上（同色底上不可见，
/// 仅指示居中）。
class _UserCollapseFade extends StatelessWidget {
  final IconData icon;

  const _UserCollapseFade({required this.icon});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AppColors>()!;
    return IgnorePointer(
      child: SizedBox(
        height: _kUserCollapseFadeHeight,
        width: double.infinity,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [colors.userBubble.withAlpha(0), colors.userBubble],
            ),
            borderRadius: const BorderRadius.vertical(
              bottom: Radius.circular(14),
            ),
          ),
          child: Center(
            child: Icon(icon, size: 20, color: colors.userText),
          ),
        ),
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  final String sessionId;
  final String directory;
  final TextEditingController ctl;
  final bool busy;
  final bool disabled;
  final Future<bool> Function() onAbort;
  final ValueChanged<String> onChanged;
  final VoidCallback onSend;
  final ValueNotifier<bool> farFromBottom;
  final VoidCallback onScrollToBottom;
  final List<_PendingItem> pending;
  final bool shellMode;
  final VoidCallback onExitShellMode;
  final VoidCallback onPickAttachments;
  final ValueChanged<int> onRemove;

  const _BottomBar({
    required this.sessionId,
    required this.directory,
    required this.ctl,
    required this.busy,
    required this.disabled,
    required this.onAbort,
    required this.onChanged,
    required this.onSend,
    required this.farFromBottom,
    required this.onScrollToBottom,
    required this.pending,
    required this.shellMode,
    required this.onExitShellMode,
    required this.onPickAttachments,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(
          top: BorderSide(
            color:
                Theme.of(context).dividerTheme.color ?? const Color(0xFF33373E),
          ),
        ),
      ),
      child: _BottomSafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (pending.isNotEmpty)
              _FilePreviewBar(pending: pending, onRemove: onRemove),
            _ComposeBar(
              ctl: ctl,
              busy: busy,
              disabled: disabled,
              onAbort: onAbort,
              onChanged: onChanged,
              onSend: onSend,
              farFromBottom: farFromBottom,
              onScrollToBottom: onScrollToBottom,
              pending: pending,
              shellMode: shellMode,
              onExitShellMode: onExitShellMode,
              onPickAttachments: onPickAttachments,
            ),
            _AgentModelBar(sessionId: sessionId, directory: directory),
          ],
        ),
      ),
    );
  }
}

class _BottomSafeArea extends StatelessWidget {
  final Widget child;
  const _BottomSafeArea({required this.child});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom),
      child: child,
    );
  }
}

class _ComposeBar extends StatefulWidget {
  final TextEditingController ctl;
  final ValueChanged<String> onChanged;
  final VoidCallback onSend;
  final ValueNotifier<bool> farFromBottom;
  final VoidCallback onScrollToBottom;
  final bool busy;
  final bool disabled;
  final Future<bool> Function() onAbort;
  final List<_PendingItem> pending;
  final bool shellMode;
  final VoidCallback onExitShellMode;
  final VoidCallback onPickAttachments;
  const _ComposeBar({
    required this.ctl,
    required this.onChanged,
    required this.onSend,
    required this.farFromBottom,
    required this.onScrollToBottom,
    required this.busy,
    required this.disabled,
    required this.onAbort,
    required this.pending,
    required this.shellMode,
    required this.onExitShellMode,
    required this.onPickAttachments,
  });

  @override
  State<_ComposeBar> createState() => _ComposeBarState();
}

class _ComposeBarState extends State<_ComposeBar> with WidgetsBindingObserver {
  bool _aborting = false;
  final _kbFocus = FocusNode();
  final _fieldFocus = FocusNode();
  double _prevBottomInset = 0;
  bool _didInitInset = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_didInitInset) {
      _didInitInset = true;
      _prevBottomInset = View.of(context).viewInsets.bottom;
    }
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final inset = View.of(context).viewInsets.bottom;
      final route = ModalRoute.of(context);
      final obscured = route != null && !route.isCurrent;
      if (_prevBottomInset > 0 &&
          inset == 0 &&
          _fieldFocus.hasFocus &&
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed &&
          !obscured) {
        _fieldFocus.unfocus();
      }
      _prevBottomInset = inset;
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _fieldFocus.dispose();
    _kbFocus.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(_ComposeBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_aborting && oldWidget.busy && !widget.busy) {
      _aborting = false;
    }
  }

  Future<void> _onStopPressed() async {
    if (_aborting) return;
    setState(() => _aborting = true);
    final ok = await widget.onAbort();
    if (mounted && !ok) setState(() => _aborting = false);
  }

  @override
  Widget build(BuildContext context) {
    final showStop =
        widget.busy && widget.ctl.text.trim().isEmpty && widget.pending.isEmpty;
    return Padding(
      padding: const EdgeInsets.only(left: 12, right: 8, top: 8, bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: KeyboardListener(
              focusNode: _kbFocus,
              onKeyEvent: (e) {
                if (widget.shellMode &&
                    widget.ctl.text.isEmpty &&
                    e is KeyDownEvent &&
                    e.logicalKey == LogicalKeyboardKey.backspace) {
                  widget.onExitShellMode();
                }
              },
              child: TextField(
                controller: widget.ctl,
                focusNode: _fieldFocus,
                readOnly: widget.disabled,
                onTapOutside: (_) {},
                onChanged: widget.onChanged,
                onSubmitted: (_) => widget.onSend(),
                minLines: 1,
                maxLines: 4,
                decoration: InputDecoration(
                  hintText: widget.shellMode
                      ? l(context).composeShellHint
                      : l(context).composeHint,
                  hintStyle: const TextStyle(overflow: TextOverflow.ellipsis),
                  hintMaxLines: 1,
                  isDense: true,
                  prefixIcon: IconButton(
                    icon: Icon(
                      widget.shellMode ? Icons.priority_high : Icons.add,
                    ),
                    tooltip: widget.shellMode
                        ? l(context).composeShellMode
                        : l(context).composeAttachment,
                    onPressed: widget.disabled
                        ? null
                        : (widget.shellMode
                            ? widget.onExitShellMode
                            : widget.onPickAttachments),
                  ),
                  prefixIconColor: Theme.of(
                    context,
                  ).colorScheme.onSurfaceVariant,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide: BorderSide.none,
                  ),
                  fillColor: Theme.of(
                    context,
                  ).colorScheme.surfaceContainerHighest,
                  filled: true,
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          ValueListenableBuilder<bool>(
            valueListenable: widget.farFromBottom,
            builder: (context, far, _) {
              final hasInput =
                  widget.ctl.text.trim().isNotEmpty ||
                  widget.pending.isNotEmpty;
              if (!hasInput && far) {
                return IconButton.filled(
                  onPressed: widget.onScrollToBottom,
                  icon: const Icon(Icons.keyboard_double_arrow_down),
                  tooltip: l(context).scrollToBottom,
                );
              }
              if (showStop) {
                return IconButton.filled(
                  onPressed: _onStopPressed,
                  icon: _aborting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.stop_rounded),
                  tooltip: l(context).composeStop,
                  style: IconButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.error,
                  ),
                );
              }
              return IconButton.filled(
                onPressed: widget.disabled ? null : widget.onSend,
                icon: const Icon(Icons.send),
                tooltip: l(context).composeSend,
              );
            },
          ),
        ],
      ),
    );
  }
}

class _CommandHints extends StatelessWidget {
  final String query;
  final List<CommandInfo> commands;
  final bool loading;
  final ValueChanged<String> onPick;
  const _CommandHints({
    required this.query,
    required this.commands,
    required this.loading,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    final q = query.toLowerCase();
    final matches = commands
        .where((c) => c.slash.toLowerCase().startsWith(q))
        .toList();
    if (matches.isEmpty) {
      if (loading) {
        return _shell(
          context,
          ListTile(
            dense: true,
            leading: const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            title: Text(
              l(context).composeLoadingCommands,
              style: const TextStyle(fontSize: 13),
            ),
          ),
        );
      }
      return const SizedBox.shrink();
    }
    return _shell(
      context,
      ListView(
        shrinkWrap: true,
        children: matches
            .map(
              (c) => ListTile(
                dense: true,
                leading: const Icon(Icons.terminal, size: 18),
                title: Text(c.slash, style: const TextStyle(fontSize: 13)),
                subtitle: c.description.isNotEmpty
                    ? Text(
                        c.description,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(context).colorScheme.outline,
                        ),
                      )
                    : null,
                onTap: () => onPick(c.slash),
              ),
            )
            .toList(),
      ),
    );
  }

  Widget _shell(BuildContext context, Widget child) => Container(
    constraints: BoxConstraints(
      maxHeight: MediaQuery.sizeOf(context).height * 0.3,
    ),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surface,
      border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
    ),
    child: child,
  );
}

class _MoreMenu extends StatelessWidget {
  final String sessionId;
  final String directory;
  final SessionModel? session;
  const _MoreMenu({
    required this.sessionId,
    required this.directory,
    this.session,
  });

  @override
  Widget build(BuildContext context) {
    final loc = l(context);
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert),
      tooltip: loc.moreMenu,
      popUpAnimationStyle: popupMenuAnimationStyle,
      onSelected: (v) => _onSelected(context, v),
      itemBuilder: (_) => [
        PopupMenuItem(value: 'refresh', child: Text(loc.convRefresh)),
        PopupMenuItem(value: 'rename', child: Text(loc.convRename)),
        PopupMenuItem(value: 'archive', child: Text(loc.convArchive)),
      ],
    );
  }

  Future<void> _onSelected(BuildContext context, String value) async {
    switch (value) {
      case 'refresh':
        final conv = serverStore.conversationFor(sessionId);
        if (conv != null) unawaited(conv.reload());
      case 'rename':
        await _showRenameDialog(context);
      case 'archive':
        await _showArchiveDialog(context);
    }
  }

  Future<void> _showArchiveDialog(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l(ctx).convArchiveTitle),
        content: Text(l(ctx).convArchiveConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l(ctx).cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l(ctx).convArchive),
          ),
        ],
      ),
    );
    if (ok == true) {
      try {
        await serverStore.archiveSession(sessionId);
        if (context.mounted) context.pop();
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                l(context).archiveFailed(friendlyMessage(l(context), e)),
              ),
            ),
          );
        }
      }
    }
  }

  Future<void> _showRenameDialog(BuildContext context) async {
    final client = serverStore.client;
    if (client == null) return;
    final ctl = TextEditingController(text: session?.title ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l(ctx).convRename),
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: InputDecoration(
            labelText: l(ctx).convTitleLabel,
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l(ctx).cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l(ctx).save),
          ),
        ],
      ),
    );
    if (ok == true) {
      final title = ctl.text.trim();
      if (title.isEmpty) return;
      try {
        await client.updateTitle(sessionId, title);
        unawaited(serverStore.refresh());
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                l(context).renameFailed(friendlyMessage(l(context), e)),
              ),
            ),
          );
        }
      }
    }
  }
}

/// Agent / Model / Thinking variant switcher bar, shown above the compose bar.
class _AgentModelBar extends StatefulWidget {
  final String sessionId;
  final String directory;

  const _AgentModelBar({required this.sessionId, required this.directory});

  @override
  State<_AgentModelBar> createState() => _AgentModelBarState();
}

class _AgentModelBarState extends State<_AgentModelBar> {
  List<AgentInfo> _agents = const [];
  List<ModelInfo> _models = const [];
  bool _loading = false;
  bool _switching = false;
  String? _optimisticAgent;
  Timer? _emptyRetryTimer;
  int _emptyRetryCount = 0;
  static const _maxEmptyRetries = 3;

  @override
  void initState() {
    super.initState();
    _loadOptions();
  }

  @override
  void dispose() {
    _emptyRetryTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadOptions() async {
    final client = serverStore.client;
    if (client == null) return;
    setState(() => _loading = true);
    try {
      final (agents, models) = await serverStore.fetchAgentsAndModels(
        directory: widget.directory,
      );
      if (mounted) {
        setState(() {
          _agents = agents;
          _models = models;
          _loading = false;
        });
        if ((agents.isEmpty || models.isEmpty) &&
            _emptyRetryTimer == null &&
            _emptyRetryCount < _maxEmptyRetries) {
          _emptyRetryCount++;
          _emptyRetryTimer = Timer(const Duration(seconds: 2), () {
            _emptyRetryTimer = null;
            if (mounted) _loadOptions();
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              l(context).optionsLoadFailed(friendlyMessage(l(context), e)),
            ),
          ),
        );
      }
    }
  }

  Future<void> _switchAgent(String agent) async {
    final client = serverStore.client;
    if (client == null || _switching) return;
    setState(() {
      _switching = true;
      _optimisticAgent = agent;
    });
    try {
      await client.switchAgent(widget.sessionId, agent);
      final ok = await serverStore.refresh();
      if (mounted) {
        if (ok) {
          setState(() => _optimisticAgent = null);
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l(context).switchedRefreshFailed)),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _optimisticAgent = null);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              l(context).switchAgentFailed(friendlyMessage(l(context), e)),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  Future<void> _switchModel(ModelInfo model, [ModelVariant? variant]) async {
    final client = serverStore.client;
    if (client == null) return;
    setState(() => _switching = true);
    try {
      final ref = ModelRef(
        id: model.id,
        providerID: model.providerID,
        variant: variant?.id,
      );
      await client.switchModel(widget.sessionId, ref);
      unawaited(serverStore.refresh());
      unawaited(
        defaultAgentModelStore.saveDefaultModel(connectionStore.activeId, ref),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              l(context).switchModelFailed(friendlyMessage(l(context), e)),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  void _showAgentSheet() {
    if (_agents.isEmpty) return;
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: _agents
              .map(
                (a) => ListTile(
                  leading: Icon(
                    a.mode == 'primary'
                        ? Icons.person
                        : Icons.subdirectory_arrow_right,
                    size: 20,
                  ),
                  title: Text(a.name),
                  subtitle: a.description != null && a.description!.isNotEmpty
                      ? Text(
                          a.description!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        )
                      : null,
                  trailing:
                      serverStore.sessionById(widget.sessionId)?.agent == a.id
                      ? const Icon(Icons.check, size: 18)
                      : null,
                  onTap: () {
                    Navigator.pop(ctx);
                    _switchAgent(a.id);
                  },
                ),
              )
              .toList(),
        ),
      ),
    );
  }

  void _showModelSheet() {
    if (_models.isEmpty) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _ModelPickerSheet(
        models: _models,
        sessionId: widget.sessionId,
        onSelected: (m) {
          Navigator.pop(ctx);
          _switchModel(m);
        },
        onManage: () {
          // Close the sheet first, then push from this (stable) context —
          // pushing inside the sheet builder would add /models above the
          // sheet in the root navigator, so a subsequent maybePop would pop
          // /models instead of the sheet.
          Navigator.pop(ctx);
          context.push('/models');
        },
      ),
    );
  }

  void _showVariantSheet(ModelInfo model, List<ModelVariant> variants) {
    final session = serverStore.sessionById(widget.sessionId);
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              leading: const Icon(Icons.do_not_disturb, size: 20),
              title: Text(l(ctx).defaultLabel),
              trailing: session?.model?.variant == null
                  ? const Icon(Icons.check, size: 18)
                  : null,
              onTap: () {
                Navigator.pop(ctx);
                _switchModel(model);
              },
            ),
            ...variants.map(
              (v) => ListTile(
                leading: const Icon(Icons.tune, size: 20),
                title: Text(v.id),
                trailing: session?.model?.variant == v.id
                    ? const Icon(Icons.check, size: 18)
                    : null,
                onTap: () {
                  Navigator.pop(ctx);
                  _switchModel(model, v);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = scheme.outline;

    return _BarMetricsScope(child: _buildBar(context, muted));
  }

  Widget _buildBar(BuildContext context, Color muted) {
    if (_loading) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _Chip(icon: Icons.smart_toy_outlined, label: '—', muted: muted),
            const SizedBox(width: 8),
            _Chip(icon: Icons.memory, label: '—', muted: muted),
          ],
        ),
      );
    }

    return ListenableBuilder(
      listenable: serverStore,
      builder: (context, _) {
        final session = serverStore.sessionById(widget.sessionId);
        final agentId = _optimisticAgent ?? session?.agent ?? '—';
        final agentMatch = _agents.where((a) => a.id == agentId);
        final agentName = agentMatch.isEmpty ? agentId : agentMatch.first.name;
        final modelName = session?.model?.id ?? '—';

        if (_optimisticAgent != null && session?.agent == _optimisticAgent) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted &&
                _optimisticAgent != null &&
                serverStore.sessionById(widget.sessionId)?.agent ==
                    _optimisticAgent) {
              setState(() => _optimisticAgent = null);
            }
          });
        }

        // Find current model's variants for thinking level button.
        // Match both providerID and id: model ids repeat across providers
        // (e.g. deepseek-v4-flash exists under both `deepseek` and
        // `ollama-cloud`), so id-only matching would pick the wrong entry.
        final currentModel = _models
            .where(
              (m) =>
                  m.id == session?.model?.id &&
                  m.providerID == session?.model?.providerID,
            )
            .toList();
        final hasVariants =
            currentModel.isNotEmpty && currentModel.first.variants.isNotEmpty;

        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 2),
          child: IntrinsicHeight(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  if (_agents.length == 2 &&
                      _agents.any((a) => a.id == agentId))
                    _AgentCapsuleToggle(
                      agents: _agents,
                      currentAgent: agentId,
                      onSwitch: _switching ? null : _switchAgent,
                    )
                  else
                    _Chip(
                      icon: Icons.smart_toy_outlined,
                      label: agentName,
                      onTap: (_switching || _agents.length <= 1)
                          ? null
                          : _showAgentSheet,
                      muted: muted,
                    ),
                  const SizedBox(width: 8),
                  _Chip(
                    icon: Icons.memory,
                    label: modelName,
                    onTap: _switching ? null : _showModelSheet,
                    muted: muted,
                  ),
                  if (hasVariants) ...[
                    const SizedBox(width: 8),
                    _Chip(
                      icon: Icons.psychology_outlined,
                      label: session?.model?.variant ?? l(context).defaultLabel,
                      onTap: _switching
                          ? null
                          : () => _showVariantSheet(
                              currentModel.first,
                              currentModel.first.variants,
                            ),
                      muted: muted,
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _BarMetricsScope extends StatelessWidget {
  final Widget child;
  const _BarMetricsScope({required this.child});

  @override
  Widget build(BuildContext context) {
    return MediaQuery(
      // Freeze viewInsets so the bar subtree does not rebuild on every
      // keyboard-animation frame; the bar is positioned by _KeyboardAvoider
      // padding and never reads viewInsets itself.
      data: MediaQuery.of(context).copyWith(
        textScaler: MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.0),
        viewInsets: EdgeInsets.zero,
      ),
      child: child,
    );
  }
}

/// Capsule-style segmented toggle for exactly 2 agents.
/// Both options are visible side-by-side; a highlight slides to the active one.
class _AgentCapsuleToggle extends StatefulWidget {
  final List<AgentInfo> agents;
  final String currentAgent;
  final ValueChanged<String>? onSwitch;

  const _AgentCapsuleToggle({
    required this.agents,
    required this.currentAgent,
    this.onSwitch,
  });

  @override
  State<_AgentCapsuleToggle> createState() => _AgentCapsuleToggleState();
}

class _AgentCapsuleToggleState extends State<_AgentCapsuleToggle>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  final GlobalKey _stackKey = GlobalKey();
  late List<GlobalKey> _optionKeys;

  double _left = 0, _width = 0;
  double _fromLeft = 0, _fromWidth = 0;
  bool _measured = false;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _optionKeys = List.generate(widget.agents.length, (_) => GlobalKey());
    _ctrl.addListener(() {
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure(true));
  }

  @override
  void didUpdateWidget(covariant _AgentCapsuleToggle old) {
    super.didUpdateWidget(old);
    if (!identical(old.agents, widget.agents)) {
      _optionKeys = List.generate(widget.agents.length, (_) => GlobalKey());
      WidgetsBinding.instance.addPostFrameCallback((_) => _measure(true));
    } else if (old.currentAgent != widget.currentAgent) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _measure(false));
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _measure(bool initial) {
    final idx = widget.agents.indexWhere((a) => a.id == widget.currentAgent);
    final stackCtx = _stackKey.currentContext;
    if (idx < 0 || stackCtx == null) return;
    final stackBox = stackCtx.findRenderObject() as RenderBox?;
    final optionCtx = _optionKeys[idx].currentContext;
    if (stackBox == null || !stackBox.hasSize || optionCtx == null) return;
    final optionBox = optionCtx.findRenderObject() as RenderBox?;
    if (optionBox == null || !optionBox.hasSize) return;
    final pos = optionBox.localToGlobal(Offset.zero, ancestor: stackBox);
    final newLeft = pos.dx;
    final newWidth = optionBox.size.width;
    if (initial) {
      _fromLeft = _left = newLeft;
      _fromWidth = _width = newWidth;
      _measured = true;
      _ctrl.value = 1;
    } else {
      _fromLeft = _left;
      _fromWidth = _width;
      _left = newLeft;
      _width = newWidth;
      _ctrl.forward(from: 0);
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Curves.easeOutCubic.transform(_ctrl.value);
    final curLeft = _fromLeft + (_left - _fromLeft) * t;
    final curWidth = _fromWidth + (_width - _fromWidth) * t;

    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.all(2),
      child: Stack(
        key: _stackKey,
        children: [
          if (_measured)
            Positioned(
              left: curLeft,
              width: curWidth,
              top: 0,
              bottom: 0,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(13),
                  ),
                ),
              ),
            ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < widget.agents.length; i++)
                _buildOption(widget.agents[i], i, scheme),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildOption(AgentInfo a, int idx, ColorScheme scheme) {
    final active = a.id == widget.currentAgent;
    return Semantics(
      selected: active,
      button: true,
      enabled: widget.onSwitch != null && !active,
      child: GestureDetector(
        key: _optionKeys[idx],
        behavior: HitTestBehavior.opaque,
        onTap: widget.onSwitch == null || active
            ? null
            : () => widget.onSwitch!(a.id),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.smart_toy_outlined,
                size: 14,
                color: active ? scheme.onPrimaryContainer : scheme.outline,
              ),
              const SizedBox(width: 4),
              Text(
                a.name,
                style: TextStyle(
                  fontSize: 12,
                  color: active ? scheme.onPrimaryContainer : scheme.outline,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Model picker bottom sheet: search bar + models grouped by provider.
///
/// Grouping follows first-appearance order of `providerID` in [models] (server
/// order). Search matches model name, id, and providerID (case-insensitive).
/// When a search is active, empty providers are hidden; the query is reset on
/// close.
class _ModelPickerSheet extends StatefulWidget {
  final List<ModelInfo> models;
  final String sessionId;
  final ValueChanged<ModelInfo> onSelected;
  final VoidCallback? onManage;

  const _ModelPickerSheet({
    required this.models,
    required this.sessionId,
    required this.onSelected,
    this.onManage,
  });

  @override
  State<_ModelPickerSheet> createState() => _ModelPickerSheetState();
}

class _ModelPickerSheetState extends State<_ModelPickerSheet> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  bool _matches(ModelInfo m, String q) {
    if (q.isEmpty) return true;
    return m.name.toLowerCase().contains(q) ||
        m.id.toLowerCase().contains(q) ||
        m.providerID.toLowerCase().contains(q);
  }

  String? get _serverId => connectionStore.activeId;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final session = serverStore.sessionById(widget.sessionId);
    final q = _query.toLowerCase();

    // Listen to hidden-model changes so toggles in the model-management
    // page reflect here immediately.
    return ListenableBuilder(
      listenable: modelHideStore,
      builder: (context, _) {
        // Visible models: server order, grouped by providerID, excluding
        // hidden ones and search misses.
        final groups = <String, List<ModelInfo>>{};
        for (final m in widget.models) {
          if (modelHideStore.isHidden(_serverId, m.providerID, m.id)) continue;
          if (!_matches(m, q)) continue;
          (groups[m.providerID] ??= []).add(m);
        }

        return SafeArea(
          child: ConstrainedBox(
            // Cap at ~70% of the viewport height *above the open keyboard* so
            // the sheet scrolls internally when there are many models, while
            // shrinking to content (search + list) when there are few.
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.7,
            ),
            child: Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.viewInsetsOf(context).bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 4, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _controller,
                            textInputAction: TextInputAction.search,
                            style: const TextStyle(fontSize: 14),
                            decoration: InputDecoration(
                              isDense: true,
                              hintText: l(context).modelSearchHint,
                              hintStyle: TextStyle(
                                fontSize: 14,
                                color: scheme.outline,
                              ),
                              prefixIcon: Icon(
                                Icons.search,
                                size: 20,
                                color: scheme.outline,
                              ),
                              suffixIcon: _query.isEmpty
                                  ? null
                                  : IconButton(
                                      visualDensity: VisualDensity.compact,
                                      iconSize: 18,
                                      icon: const Icon(Icons.close),
                                      onPressed: () {
                                        _controller.clear();
                                        setState(() => _query = '');
                                        if (_scrollController.hasClients) {
                                          _scrollController.jumpTo(0);
                                        }
                                      },
                                    ),
                              border: InputBorder.none,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                            ),
                            onChanged: (v) {
                              setState(() => _query = v.trim());
                              if (_scrollController.hasClients) {
                                _scrollController.jumpTo(0);
                              }
                            },
                          ),
                        ),
                        IconButton(
                          tooltip: l(context).settingsModelsManage,
                          icon: const Icon(Icons.tune),
                          onPressed: widget.onManage,
                        ),
                      ],
                    ),
                  ),
                  if (groups.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 32),
                      child: Text(
                        l(context).modelNoMatch,
                        style: TextStyle(fontSize: 13, color: scheme.outline),
                      ),
                    )
                  else
                    Flexible(
                      fit: FlexFit.loose,
                      child: ListView(
                        controller: _scrollController,
                        padding: const EdgeInsets.only(bottom: 8),
                        children: _buildGroups(groups, session, scheme),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  List<Widget> _buildGroups(
    Map<String, List<ModelInfo>> groups,
    SessionModel? session,
    ColorScheme scheme,
  ) {
    final out = <Widget>[];
    for (final providerID in groups.keys) {
      final items = groups[providerID]!;
      out.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 12, 4),
          child: Row(
            children: [
              Icon(Icons.dns_outlined, size: 14, color: scheme.outline),
              const SizedBox(width: 6),
              Text(
                providerID,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: scheme.outline,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '${items.length}',
                style: TextStyle(fontSize: 11, color: scheme.outline),
              ),
            ],
          ),
        ),
      );
      for (final m in items) {
        final selected =
            session?.model?.id == m.id &&
            session?.model?.providerID == m.providerID;
        out.add(
          ListTile(
            dense: true,
            leading: const Icon(Icons.memory, size: 20),
            title: Text(m.name, style: const TextStyle(fontSize: 14)),
            subtitle: Text(
              '${m.providerID}/${m.id}',
              style: AppTheme.mono.copyWith(fontSize: 11),
            ),
            trailing: selected ? const Icon(Icons.check, size: 18) : null,
            onTap: () => widget.onSelected(m),
          ),
        );
      }
    }
    return out;
  }
}

class _Chip extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final Color muted;

  const _Chip({
    required this.icon,
    required this.label,
    this.onTap,
    required this.muted,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: muted),
            const SizedBox(width: 4),
            Text(label, style: TextStyle(fontSize: 12, color: muted)),
            const SizedBox(width: 2),
            Icon(Icons.expand_more, size: 14, color: muted),
          ],
        ),
      ),
    );
  }
}
