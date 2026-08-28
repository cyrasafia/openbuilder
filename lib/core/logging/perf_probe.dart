import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'app_logger.dart';

/// 常驻掉帧探针（debug/profile 才生效，release 树摇为空）。
///
/// 设计依据 design-frame-drop.md §0.2 / §3.2 的 OverlayPerfProbe / KbPerf 方法，
/// 沉淀为可长期挂载的版本，供任意页面/转场/SSE 窗口抓帧定位主因：
///
/// - `start()`：装 `SchedulerBinding.addTimingsCallback`，每帧记录
///   `FrameTiming.buildDuration` / `rasterDuration`，超预算的帧写入 AppLogger。
/// - `debugOnRebuildDirtyWidget`（仅 debug）：按帧聚合脏 widget 类型 + landmark，
///   profile 模式无此回调（框架 debug-only），但帧耗时与事件标记仍可用。
/// - `beginWindow(label)` / `endWindow(label)`：窗口化抓帧（如"进入会话 X"），
///   收尾输出 frames / buildMax / buildMed / rasterMax / over8.3 / over16.7 /
///   rebuilds / types / landmarks。
/// - `markEvent(label)`：点事件（SSE 事件、refresh start/done、reconcile done 等），
///   与帧数据同日志流，用于长帧归因。
///
/// 预算按 120Hz（8.3ms）计——本项目 main.dart:34 setHighRefreshRate()，目标机多为
/// 120Hz。60Hz 机型可放宽，但留档统一按 8.3ms 判定便于横向对比。
///
/// 用法（main.dart，init 后）：
///   if (kDebugMode || kProfileMode) PerfProbe.I.start();
///
/// 窗口化抓帧（进入会话页）：
///   PerfProbe.I.beginWindow('enter-session:$sid');
///   ... 转场/加载 ...
///   PerfProbe.I.endWindow('enter-session:$sid');
///
/// 点事件：
///   PerfProbe.I.markEvent('reconcile-done $sid');
///
/// 诊断代码原则：release 早退、无副作用；窗口/事件 API 在未 start 时为 no-op。
class PerfProbe {
  PerfProbe._();
  static final PerfProbe I = PerfProbe._();

  static const _tag = 'PerfProbe';
  static const Duration _budget120 = Duration(microseconds: 8333);
  static const Duration _budget60 = Duration(microseconds: 16667);
  static const int _ringMax = 600; // ~10s @60fps

  bool _started = false;
  final _ring = Queue<_FrameSample>();
  final _windows = <String, _Window>{};
  final _events = <_Event>[];
  // debug-only rebuild tracking
  final _rebuildsByFrame = <int, _RebuildBucket>{};
  int _currentFrameSeq = 0;

  void start() {
    if (_started) return;
    _started = true;
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    if (kDebugMode) {
      // debugOnRebuildDirtyWidget is a debug-only callback; absent in profile.
      debugOnRebuildDirtyWidget = _onRebuildDirtyWidget;
    }
    AppLogger.I.i(_tag, 'started (mode=${kDebugMode ? "debug" : "profile"})');
  }

  void stop() {
    if (!_started) return;
    _started = false;
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    if (kDebugMode) {
      debugOnRebuildDirtyWidget = null;
    }
    _ring.clear();
    _windows.clear();
    _events.clear();
    _rebuildsByFrame.clear();
  }

  bool get isStarted => _started;

  // ---- Window API ---------------------------------------------------------

  void beginWindow(String label) {
    if (!_started) return;
    _windows[label] = _Window(label: label, startSeq: _currentFrameSeq);
    AppLogger.I.i(_tag, 'window begin "$label"');
  }

  void endWindow(String label) {
    if (!_started) return;
    final w = _windows.remove(label);
    if (w == null) return;
    final summary = _summarizeWindow(w);
    AppLogger.I.i(_tag, summary);
    debugPrint('[$_tag] $summary');
  }

  // ---- Event API ----------------------------------------------------------

  void markEvent(String label) {
    if (!_started) return;
    final ev = _Event(label: label, seq: _currentFrameSeq);
    _events.add(ev);
    if (_events.length > 200) _events.removeRange(0, _events.length - 200);
    final msg = '[$_tag] event "$label" @frame=$_currentFrameSeq';
    AppLogger.I.d(_tag, msg);
    if (kProfileMode) debugPrint(msg);
  }

  // ---- internals ----------------------------------------------------------

  void _onTimings(List<FrameTiming> timings) {
    for (final t in timings) {
      _currentFrameSeq++;
      final sample = _FrameSample(
        seq: _currentFrameSeq,
        build: t.buildDuration,
        raster: t.rasterDuration,
      );
      _ring.addLast(sample);
      if (_ring.length > _ringMax) _ring.removeFirst();
      // Log jank frames immediately (with any nearby events for attribution).
      if (sample.build > _budget120 || sample.raster > _budget120) {
        _logJank(sample);
      }
    }
  }

  void _logJank(_FrameSample s) {
    final over8 = s.build > _budget120 || s.raster > _budget120;
    final over16 = s.build > _budget60 || s.raster > _budget60;
    if (!over8) return;
    final nearby = _events
        .where((e) => (e.seq - s.seq).abs() <= 3)
        .map((e) => e.label)
        .join(', ');
    final bucket = _rebuildsByFrame[s.seq];
    final types = bucket == null ? '' : _fmtTypes(bucket.types);
    final landmarks = bucket == null ? '' : _fmtTypes(bucket.landmarks);
    final msg = '[$_tag] jank frame=${s.seq} '
        'build=${s.build.inMicroseconds}us raster=${s.raster.inMicroseconds}us '
        'over8.3=$over8 over16.7=$over16'
        '${nearby.isEmpty ? '' : ' events=[$nearby]'}'
        '${types.isEmpty ? '' : ' types=$types'}'
        '${landmarks.isEmpty ? '' : ' landmarks=$landmarks'}';
    AppLogger.I.w(_tag, msg);
    if (kProfileMode) debugPrint(msg);
  }

  String _summarizeWindow(_Window w) {
    final samples = _ring.where((s) => s.seq >= w.startSeq).toList();
    if (samples.isEmpty) return 'window "${w.label}": no frames captured';
    final builds = samples.map((s) => s.build.inMicroseconds).toList()
      ..sort();
    final rasters = samples.map((s) => s.raster.inMicroseconds).toList()
      ..sort();
    final buildMax = builds.last;
    final buildMed = builds[builds.length ~/ 2];
    final rasterMax = rasters.last;
    final over8 = samples.where(
      (s) => s.build > _budget120 || s.raster > _budget120).length;
    final over16 = samples.where(
      (s) => s.build > _budget60 || s.raster > _budget60).length;
    // Rebuild aggregation across window frames.
    final types = <String, int>{};
    final landmarks = <String, int>{};
    var rebuilds = 0;
    for (final s in samples) {
      final b = _rebuildsByFrame[s.seq];
      if (b == null) continue;
      rebuilds += b.count;
      b.types.forEach((k, v) => types[k] = (types[k] ?? 0) + v);
      b.landmarks.forEach((k, v) => landmarks[k] = (landmarks[k] ?? 0) + v);
    }
    final winEvents = _events
        .where((e) => e.seq >= w.startSeq)
        .map((e) => '${e.label}@${e.seq}')
        .join(', ');
    return 'window "${w.label}": frames=${samples.length} '
        'buildMax=${buildMax}us buildMed=${buildMed}us rasterMax=${rasterMax}us '
        'over8.3=$over8 over16.7=$over16 rebuilds=$rebuilds'
        '${types.isEmpty ? '' : ' types=${_fmtTypes(types)}'}'
        '${landmarks.isEmpty ? '' : ' landmarks=${_fmtTypes(landmarks)}'}'
        '${winEvents.isEmpty ? '' : ' events=[$winEvents]'}';
  }

  String _fmtTypes(Map<String, int> m) {
    if (m.isEmpty) return '';
    final entries = m.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return entries.map((e) => '${e.key}:${e.value}').join(',');
  }

  void _onRebuildDirtyWidget(Element element, bool builtOnce) {
    // frameSeq from framework is the build frame index; map to our seq by
    // using the most recent frame. We aggregate by widget runtimeType +
    // nearest landmark (a StatefulWidget/StatelessWidget ancestor name).
    final seq = _currentFrameSeq;
    final bucket = _rebuildsByFrame.putIfAbsent(seq, () => _RebuildBucket());
    bucket.count++;
    final type = element.widget.runtimeType.toString();
    bucket.types[type] = (bucket.types[type] ?? 0) + 1;
    final lm = _landmarkOf(element);
    if (lm != null) {
      bucket.landmarks[lm] = (bucket.landmarks[lm] ?? 0) + 1;
    }
    if (_rebuildsByFrame.length > 300) {
      // Evict oldest buckets to bound memory.
      final keys = _rebuildsByFrame.keys.toList()..sort();
      for (var i = 0; i < 100 && i < keys.length; i++) {
        _rebuildsByFrame.remove(keys[i]);
      }
    }
  }

  /// Nearest named StatefulWidget/StatelessWidget ancestor — a coarse
  /// "which screen" landmark. Trims private leading underscore for clarity.
  String? _landmarkOf(Element e) {
    String? result;
    e.visitAncestorElements((node) {
      final w = node.widget;
      if (w is StatefulWidget || w is StatelessWidget) {
        final name = w.runtimeType.toString();
        if (!name.startsWith('_') || name.length > 3) {
          result = name.replaceFirst(RegExp(r'^_'), '');
          return false; // stop
        }
      }
      return true; // continue
    });
    return result;
  }
}

class _FrameSample {
  final int seq;
  final Duration build;
  final Duration raster;
  const _FrameSample({
    required this.seq,
    required this.build,
    required this.raster,
  });
}

class _Window {
  final String label;
  final int startSeq;
  const _Window({required this.label, required this.startSeq});
}

class _Event {
  final String label;
  final int seq;
  const _Event({required this.label, required this.seq});
}

class _RebuildBucket {
  int count = 0;
  final Map<String, int> types = {};
  final Map<String, int> landmarks = {};
}