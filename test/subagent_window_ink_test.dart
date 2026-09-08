import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:open_builder/app_state.dart';
import 'package:open_builder/data/api/opencode_client.dart';
import 'package:open_builder/domain/models.dart';
import 'package:open_builder/features/conversation/conversation_screen.dart';
import 'package:open_builder/l10n/gen/app_localizations.dart';
import 'package:open_builder/ui/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Subagent 窗口（_SubagentBody）的水墨契约：
/// 窗口内 ToolChip 的 InkWell 水墨（splash/highlight）不得绘制到窗口
/// clip 之外。窗口内必须自带 Material——否则 ink 解析到 Scaffold 级
/// Material（窗口 ClipPath 之外），展开态 chip 的 ink 矩形远大于窗口
/// 可见区，水墨可越出窗口（「阴影逃出窗口」）。方法：splash/highlight
/// 染成洋红，逐帧扫描窗口下方区域的栅格像素。

class _MockClient extends OpencodeClient {
  final Map<String, List<MessageEntry>> entriesBySession;
  _MockClient(this.entriesBySession) : super(_noopDio());

  @override
  Future<MessagesPage> messagesPage(
    String sessionId, {
    required int limit,
    String? before,
  }) async =>
      MessagesPage(entriesBySession[sessionId] ?? const [], null);

  @override
  Future<List<Todo>> todos(String sessionId) async => [];
}

Dio _noopDio() => Dio(
      BaseOptions(
        connectTimeout: const Duration(milliseconds: 1),
        receiveTimeout: const Duration(milliseconds: 1),
      ),
    );

const targetSummary = 'bash: sed -n 1,80p build.gradle';

MessageEntry _msg(String sid, String id, int created, String role,
    List<MessagePart> parts) {
  return MessageEntry(
    info: MessageInfo(
      id: id,
      role: role,
      sessionID: sid,
      created: created,
      finish: 'stop',
    ),
    parts: parts,
  );
}

MessagePart _toolPart(
        String id, String tool, Map<String, dynamic> input, String output) =>
    MessagePart({
      'type': 'tool',
      'id': id,
      'tool': tool,
      'state': {
        'status': 'completed',
        'input': input,
        'output': output,
      },
    });

MessagePart _textPart(String id, String text) => MessagePart({
      'type': 'text',
      'id': id,
      'text': text,
    });

void main() {
  testWidgets('inner chip ink stays inside subagent window', (tester) async {
    tester.view.physicalSize = const Size(412, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    const kid = 'kid';
    final childMessages = <MessageEntry>[
      _msg(kid, 'c0', 10, 'user', [_textPart('cp0', 'child task prompt')]),
      for (var i = 1; i <= 7; i++)
        _msg(kid, 'c$i', 10 + i, 'assistant', [
          _toolPart('ct$i', 'bash', {'command': 'git step $i'}, 'ok $i'),
        ]),
      _msg(kid, 'c8', 30, 'assistant', [
        _toolPart(
          'ct8',
          'bash',
          {'command': 'sed -n 1,80p build.gradle'},
          List.generate(80, (i) => 'plugins { id "com.example.line$i" }')
              .join('\n'),
        ),
      ]),
    ];
    final parentMessages = <MessageEntry>[
      _msg('px', 'm1', 1, 'assistant', [
        MessagePart({
          'type': 'tool',
          'id': 'pm1',
          'tool': 'task',
          'state': {
            'status': 'completed',
            'input': {
              'subagent_type': 'explore',
              'description': '调研仓库结构',
            },
            'metadata': {'sessionId': kid},
          },
        }),
      ]),
      _msg('px', 'm2', 2, 'assistant',
          [_textPart('pm2', 'below panel sentinel text')]),
      for (var i = 3; i <= 5; i++)
        _msg('px', 'm$i', i, 'user',
            [_textPart('pm$i', 'newer message $i fills the bottom area')]),
    ];

    final rootKey = GlobalKey();
    final theme = AppTheme.light.copyWith(
      splashColor: const Color(0xFFCC00CC),
      highlightColor: const Color(0xFFCC00CC),
      hoverColor: const Color(0xFFCC00CC),
      // Android+Material3 默认 InkSparkle 在 widget test 光栅化器中不绘制，
      // 不强制 InkRipple 的话本测试对任何实现都会空洞通过
      splashFactory: InkRipple.splashFactory,
    );

    SharedPreferences.setMockInitialValues({});
    serverStore.client = _MockClient({
      'px': parentMessages,
      kid: childMessages,
    });
    await tester.pumpWidget(
      RepaintBoundary(
        key: rootKey,
        child: MaterialApp.router(
          locale: const Locale('zh'),
          theme: theme,
          darkTheme: AppTheme.dark,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: GoRouter(
            initialLocation: '/session/px',
            routes: [
              GoRoute(
                path: '/session/:id',
                builder: (_, s) =>
                    ConversationScreen(sessionId: s.pathParameters['id']!),
              ),
            ],
          ),
        ),
      ),
    );
    final boundary =
        rootKey.currentContext!.findRenderObject() as RenderRepaintBoundary;

    Future<Uint32List> capture() async {
      final image =
          await tester.runAsync(() => boundary.toImage(pixelRatio: 1.0));
      final data = await tester.runAsync(
          () => image!.toByteData(format: ui.ImageByteFormat.rawRgba));
      image!.dispose();
      return data!.buffer.asUint32List();
    }

    Future<void> settle(bool Function() probe) async {
      for (var i = 0; i < 60 && !probe(); i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));
    }

    await settle(() => find.text('Explore').evaluate().isNotEmpty);
    await tester.tap(find.text('Explore'));
    await settle(() => find.text(targetSummary).evaluate().isNotEmpty);

    // 定位窗口 clip：目标 chip 摘要向上第一个 RenderClipPath（= _SubagentBody）
    RenderObject node = tester.renderObject(find.text(targetSummary));
    while (node is! RenderClipPath) {
      node = node.parent!;
    }
    final windowBox = node as RenderBox;
    final windowBottom =
        windowBox.localToGlobal(Offset.zero).dy + windowBox.size.height;
    final y0 = windowBottom.ceil() + 2;
    final y1 = math.min(windowBottom.ceil() + 170, 900);
    expect(windowBottom, lessThan(760),
        reason: '几何准备失败：窗口应整体可见于输入框上方');

    int inkBelow(Uint32List px) {
      var n = 0;
      for (var y = y0; y < y1; y++) {
        for (var x = 0; x < 412; x++) {
          if (px[y * 412 + x] == 0xffcc00cc) n++;
        }
      }
      return n;
    }

    // 按住再抬起（真实手指时序，水墨有成长时间），展开后先收起恢复原状。
    // 注：水墨被 contained InkWell 裁剪到 chip pill 矩形内，而 pill 背景对
    // 父级 Material 不透明——窗口内的水墨本就不可见（与修复前一致），
    // 无法断言「窗口内必有水墨」；本测试守护的是「窗口外不得有水墨」，
    // 对未修复代码可稳定失败（水墨画在 Scaffold 级 Material、页面透明处
    // 显形——即窗口下方区域）。
    Future<void> pressAndScan(String tag) async {
      final gesture =
          await tester.startGesture(tester.getCenter(find.text(targetSummary)));
      for (var f = 0; f < 9; f++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(inkBelow(await capture()), 0,
            reason: '$tag hold frame $f: ink painted below subagent window');
      }
      await gesture.up();
      for (var f = 0; f < 10; f++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(inkBelow(await capture()), 0,
            reason: '$tag release frame $f: ink below subagent window');
      }
    }

    await pressAndScan('expand-newest');
    await pressAndScan('collapse-newest');
  });
}
