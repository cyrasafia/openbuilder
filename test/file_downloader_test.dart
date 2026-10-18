import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/core/connection/connection_profile.dart';
import 'package:open_builder/core/net/dio_factory.dart';
import 'package:open_builder/core/net/file_downloader.dart';
import 'package:open_builder/core/net/raw_download.dart';
import 'package:open_builder/data/api/opencode_client.dart';

const _baseUrl = 'http://api.test';
const _dir = '/w';
const _path = 'a.bin';

class _BodyPlan {
  final int status;
  final Map<String, List<String>> headers;
  final List<Uint8List> chunks;
  _BodyPlan(this.status, this.headers, this.chunks);
}

typedef _Responder = _BodyPlan Function(RequestOptions options);

class _Script {
  final _Responder respond;
  final Duration chunkDelay;
  final bool hangUntilCancelled;
  _Script(this.respond,
      {this.chunkDelay = Duration.zero, this.hangUntilCancelled = false});
}

class _Adapter implements HttpClientAdapter {
  final List<_Script> script = [];
  final List<RequestOptions> requests = [];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    assert(script.isNotEmpty, 'unexpected request #${requests.length}');
    final s = script.removeAt(0);
    final plan = s.respond(options);
    final ctl = StreamController<Uint8List>();
    unawaited(() async {
      try {
        for (final c in plan.chunks) {
          if (s.chunkDelay > Duration.zero) {
            await Future<void>.delayed(s.chunkDelay);
          }
          if (ctl.isClosed) return;
          ctl.add(c);
        }
        if (s.hangUntilCancelled) {
          await (cancelFuture ?? Completer<void>().future);
          if (!ctl.isClosed) {
            ctl.addError(DioException(
              requestOptions: options,
              type: DioExceptionType.cancel,
            ));
          }
        }
      } on Object {
        // consumer gone; nothing to deliver
      } finally {
        if (!ctl.isClosed) await ctl.close();
      }
    }());
    return ResponseBody(ctl.stream, plan.status, headers: plan.headers);
  }
}

String? _h(RequestOptions o, String name) {
  for (final e in o.headers.entries) {
    if (e.key.toLowerCase() == name) return e.value?.toString();
  }
  return null;
}

List<Uint8List> _chunked(List<int> src) => [
      for (var i = 0; i < src.length; i += 100)
        Uint8List.fromList(
            src.sublist(i, math.min(i + 100, src.length))),
    ];

_BodyPlan _full200(List<int> src,
    {required String etag, required String lm, String mime = 'application/octet-stream'}) {
  return _BodyPlan(200, {
    'content-length': ['${src.length}'],
    'etag': [etag],
    'last-modified': [lm],
    'content-type': [mime],
  }, _chunked(src));
}

_Responder _rangeAware(List<int> src,
    {required String etag, required String lm, String mime = 'application/octet-stream'}) {
  return (o) {
    final ifRange = _h(o, 'if-range');
    if (ifRange != null && ifRange != lm && ifRange != etag) {
      return _full200(src, etag: etag, lm: lm, mime: mime);
    }
    final range = _h(o, 'range');
    if (range == null) return _full200(src, etag: etag, lm: lm, mime: mime);
    final start = int.parse(range.substring(6, range.length - 1));
    if (start >= src.length) {
      return _BodyPlan(416, {'content-range': ['bytes */${src.length}']}, const []);
    }
    final body = src.sublist(start);
    return _BodyPlan(206, {
      'content-range': ['bytes $start-${src.length - 1}/${src.length}'],
      'content-length': ['${body.length}'],
      'etag': [etag],
      'last-modified': [lm],
      'content-type': [mime],
    }, _chunked(body));
  };
}

List<int> _src(int n) => List<int>.generate(n, (i) => i & 0xff);

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ob_dl_test');
  });
  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  Dio dio() => Dio(BaseOptions(baseUrl: _baseUrl));

  FileDownloader dl(_Adapter a) => FileDownloader(
        dioBuilder: (base) => rawDownloadDio(base)..httpClientAdapter = a,
        tempDir: () async => tmp,
      );

  String key() => sha256
      .convert(utf8.encode('$_baseUrl\u0000$_dir\u0000$_path'))
      .toString()
      .substring(0, 32);

  File part() => File('${tmp.path}/ob_download/${key()}.part');
  File metaFile() => File('${tmp.path}/ob_download/${key()}.meta.json');

  void seed(List<int> bytes,
      {required int total,
      String? etag,
      String? lm,
      String? mime,
      bool completed = false}) {
    Directory('${tmp.path}/ob_download').createSync(recursive: true);
    part().writeAsBytesSync(bytes);
    metaFile().writeAsStringSync(jsonEncode({
      'v': 1,
      'total': total,
      'etag': ?etag,
      'lastModified': ?lm,
      'mimeType': ?mime,
      'completed': completed,
      'updatedAt': 0,
    }));
  }

  test('parseContentRange accepts standard, star and rejects malformed', () {
    final ok = parseContentRange('bytes 0-99/29775');
    expect(ok!.start, 0);
    expect(ok.end, 99);
    expect(ok.total, 29775);
    final star = parseContentRange('bytes */29775');
    expect(star!.start, isNull);
    expect(star.end, isNull);
    expect(star.total, 29775);
    expect(parseContentRange('BYTES 0-99/29775')!.total, 29775);
    expect(parseContentRange('bytes 100-99/29775'), isNull);
    expect(parseContentRange('garbage'), isNull);
    expect(parseContentRange(null), isNull);
  });

  test('fresh 200 writes spool + meta, no Range, identity encoding', () async {
    final a = _Adapter();
    final src = _src(1000);
    a.script.add(_Script(_rangeAware(src, etag: 'W/"v1"', lm: 'LM1')));
    final progress = <(int, int, int)>[];
    final result = await dl(a).download(
      dio: dio(),
      directory: _dir,
      path: _path,
      onProgress: (r, rec, t) => progress.add((r, rec, t)),
    );
    expect(result.total, 1000);
    expect(result.resumed, false);
    expect(result.mimeType, 'application/octet-stream');
    expect(await result.file.readAsBytes(), src);
    expect(_h(a.requests.single, 'range'), isNull);
    expect(_h(a.requests.single, 'if-range'), isNull);
    expect(_h(a.requests.single, 'accept-encoding'), 'identity');
    final meta = jsonDecode(await metaFile().readAsString());
    expect(meta['completed'], true);
    expect(meta['total'], 1000);
    expect(meta['etag'], 'W/"v1"');
    expect(meta['lastModified'], 'LM1');
    expect(progress.first, (0, 100, 1000));
    expect(progress.last, (0, 1000, 1000));
  });

  test('resume sends Range + If-Range(last-modified) and appends', () async {
    final a = _Adapter();
    final src = _src(1000);
    seed(src.sublist(0, 400), total: 1000, etag: 'W/"v1"', lm: 'LM1');
    a.script.add(_Script(_rangeAware(src, etag: 'W/"v1"', lm: 'LM1')));
    final progress = <(int, int, int)>[];
    final result = await dl(a).download(
      dio: dio(),
      directory: _dir,
      path: _path,
      onProgress: (r, rec, t) => progress.add((r, rec, t)),
    );
    expect(_h(a.requests.single, 'range'), 'bytes=400-');
    expect(_h(a.requests.single, 'if-range'), 'LM1');
    expect(result.resumed, true);
    expect(await result.file.readAsBytes(), src);
    expect(progress.last, (400, 600, 1000));
  });

  test('If-Range prefers strong etag over last-modified', () async {
    final a = _Adapter();
    final src = _src(1000);
    seed(src.sublist(0, 400), total: 1000, etag: '"strong"', lm: 'LM1');
    a.script.add(_Script(_rangeAware(src, etag: '"strong"', lm: 'LM1')));
    await dl(a).download(dio: dio(), directory: _dir, path: _path);
    expect(_h(a.requests.single, 'if-range'), '"strong"');
  });

  test('stale If-Range → 200 full restart with new validators', () async {
    final a = _Adapter();
    final src = _src(1000);
    seed(src.sublist(0, 400), total: 1000, etag: 'W/"old"', lm: 'OLD');
    a.script.add(_Script(_rangeAware(src, etag: 'W/"new"', lm: 'NEW')));
    final result = await dl(a).download(
        dio: dio(), directory: _dir, path: _path);
    expect(_h(a.requests.single, 'range'), 'bytes=400-');
    expect(_h(a.requests.single, 'if-range'), 'OLD');
    expect(result.resumed, false);
    expect(await result.file.readAsBytes(), src);
    final meta = jsonDecode(await metaFile().readAsString());
    expect(meta['lastModified'], 'NEW');
    expect(meta['etag'], 'W/"new"');
    expect(meta['completed'], true);
  });

  test('complete spool → 416 zero-transfer reuse, mime from sidecar',
      () async {
    final a = _Adapter();
    final src = _src(1000);
    seed(src, total: 1000, etag: 'W/"v1"', lm: 'LM1', mime: 'text/x-test');
    a.script.add(_Script(_rangeAware(src, etag: 'W/"v1"', lm: 'LM1')));
    final result = await dl(a).download(
        dio: dio(), directory: _dir, path: _path);
    expect(a.requests, hasLength(1));
    expect(_h(a.requests.single, 'range'), 'bytes=1000-');
    expect(result.resumed, true);
    expect(result.total, 1000);
    expect(result.mimeType, 'text/x-test');
    expect(await result.file.readAsBytes(), src);
  });

  test('206 start beyond local size → drained, fresh 200 restart', () async {
    final a = _Adapter();
    final src = _src(1000);
    seed(src.sublist(0, 400), total: 1000, etag: 'W/"v1"', lm: 'LM1');
    a.script.add(_Script((o) => _BodyPlan(206, {
          'content-range': ['bytes 500-999/1000'],
          'content-length': ['500'],
          'etag': ['W/"v1"'],
          'last-modified': ['LM1'],
          'content-type': ['application/octet-stream'],
        }, [Uint8List.fromList(src.sublist(500))])));
    a.script.add(_Script(_rangeAware(src, etag: 'W/"v1"', lm: 'LM1')));
    final result = await dl(a).download(
        dio: dio(), directory: _dir, path: _path);
    expect(a.requests, hasLength(2));
    expect(_h(a.requests[1], 'range'), isNull);
    expect(result.resumed, false);
    expect(await result.file.readAsBytes(), src);
  });

  test('206 start below local size → dirty tail truncated then appended',
      () async {
    final a = _Adapter();
    final src = _src(1000);
    final dirty = [...src.sublist(0, 400), ...List<int>.filled(300, 0xff)];
    seed(dirty, total: 1000, etag: 'W/"v1"', lm: 'LM1');
    a.script.add(_Script((o) => _BodyPlan(206, {
          'content-range': ['bytes 400-999/1000'],
          'content-length': ['600'],
          'etag': ['W/"v1"'],
          'last-modified': ['LM1'],
          'content-type': ['application/octet-stream'],
        }, [Uint8List.fromList(src.sublist(400))],
        )));
    final result = await dl(a).download(
        dio: dio(), directory: _dir, path: _path);
    expect(result.resumed, true);
    expect(await result.file.readAsBytes(), src);
  });

  test('short body → FileDownloadIncompleteException, partial kept',
      () async {
    final a = _Adapter();
    final src = _src(1000);
    a.script.add(_Script((o) => _BodyPlan(200, {
          'content-length': ['1000'],
          'etag': ['W/"v1"'],
          'last-modified': ['LM1'],
          'content-type': ['application/octet-stream'],
        }, [Uint8List.fromList(src.sublist(0, 300))])));
    await expectLater(
      dl(a).download(dio: dio(), directory: _dir, path: _path),
      throwsA(isA<FileDownloadIncompleteException>()),
    );
    expect(await part().length(), 300);
    expect(jsonDecode(await metaFile().readAsString())['total'], 1000);
  });

  test('non-identity content-encoding → spool deleted and throws', () async {
    final a = _Adapter();
    final src = _src(1000);
    seed(src.sublist(0, 400), total: 1000, etag: 'W/"v1"', lm: 'LM1');
    a.script.add(_Script((o) => _BodyPlan(206, {
          'content-range': ['bytes 400-999/1000'],
          'content-length': ['600'],
          'content-encoding': ['gzip'],
          'etag': ['W/"v1"'],
          'last-modified': ['LM1'],
          'content-type': ['application/octet-stream'],
        }, [Uint8List.fromList(src.sublist(400))])));
    await expectLater(
      dl(a).download(dio: dio(), directory: _dir, path: _path),
      throwsA(isA<StateError>()),
    );
    expect(part().existsSync(), false);
    expect(metaFile().existsSync(), false);
  });

  test('orphan .part without meta → fresh full download', () async {
    final a = _Adapter();
    final src = _src(1000);
    Directory('${tmp.path}/ob_download').createSync(recursive: true);
    part().writeAsBytesSync([1, 2, 3]);
    a.script.add(_Script(_rangeAware(src, etag: 'W/"v1"', lm: 'LM1')));
    final result = await dl(a).download(
        dio: dio(), directory: _dir, path: _path);
    expect(_h(a.requests.single, 'range'), isNull);
    expect(await result.file.readAsBytes(), src);
  });

  test('server error keeps spool for later resume', () async {
    final a = _Adapter();
    seed(_src(400), total: 1000, etag: 'W/"v1"', lm: 'LM1');
    a.script.add(_Script(
        (o) => _BodyPlan(500, {'content-type': ['text/plain']}, const [])));
    await expectLater(
      dl(a).download(dio: dio(), directory: _dir, path: _path),
      throwsA(isA<DioException>()),
    );
    expect(part().existsSync(), true);
    expect(metaFile().existsSync(), true);
  });

  test('concurrent downloads join a single task', () async {
    final a = _Adapter();
    final src = _src(1000);
    a.script.add(_Script(_rangeAware(src, etag: 'W/"v1"', lm: 'LM1'),
        chunkDelay: const Duration(milliseconds: 5)));
    final d = dl(a);
    final f1 = d.download(dio: dio(), directory: _dir, path: _path);
    final f2 = d.download(dio: dio(), directory: _dir, path: _path);
    final r1 = await f1;
    final r2 = await f2;
    expect(a.requests, hasLength(1));
    expect(r1.file.path, r2.file.path);
    expect(await r1.file.readAsBytes(), src);
  });

  test('one of two voters cancels → the other still completes', () async {
    final a = _Adapter();
    final src = _src(1000);
    a.script.add(_Script(_rangeAware(src, etag: 'W/"v1"', lm: 'LM1'),
        chunkDelay: const Duration(milliseconds: 5)));
    final d = dl(a);
    final tokenA = CancelToken();
    final tokenB = CancelToken();
    final fA =
        d.download(dio: dio(), directory: _dir, path: _path, cancelToken: tokenA);
    final fB =
        d.download(dio: dio(), directory: _dir, path: _path, cancelToken: tokenB);
    await Future<void>.delayed(const Duration(milliseconds: 2));
    tokenA.cancel();
    Object? caught;
    try {
      await fA;
    } catch (e) {
      caught = e;
    }
    expect(caught, isA<DioException>());
    expect((caught as DioException).type, DioExceptionType.cancel);
    final rB = await fB;
    expect(a.requests, hasLength(1));
    expect(await rB.file.readAsBytes(), src);
  });

  test('all voters cancel → partial retained → next download resumes',
      () async {
    final a = _Adapter();
    final src = _src(1000);
    a.script.add(_Script((o) => _BodyPlan(200, {
          'content-length': ['1000'],
          'etag': ['W/"v1"'],
          'last-modified': ['LM1'],
          'content-type': ['application/octet-stream'],
        }, _chunked(src.sublist(0, 300))),
        chunkDelay: const Duration(milliseconds: 4), hangUntilCancelled: true));
    final d = dl(a);
    final token = CancelToken();
    final f = d.download(
        dio: dio(), directory: _dir, path: _path, cancelToken: token);
    var flowing = false;
    for (var i = 0; i < 500 && !flowing; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
      flowing = await part().exists() && await part().length() > 0;
    }
    expect(flowing, isTrue, reason: 'download should start writing bytes');
    token.cancel();
    Object? caught;
    try {
      await f;
    } catch (e) {
      caught = e;
    }
    expect(caught, isA<DioException>());
    expect((caught as DioException).type, DioExceptionType.cancel);
    final size = await part().length();
    expect(size, greaterThan(0));
    expect(size, lessThan(1000));
    a.script.add(_Script(_rangeAware(src, etag: 'W/"v1"', lm: 'LM1')));
    final result = await d.download(
        dio: dio(), directory: _dir, path: _path);
    expect(_h(a.requests[1], 'range'), 'bytes=$size-');
    expect(result.resumed, true);
    expect(await result.file.readAsBytes(), src);
  });

  test('download issued while task is cancelling waits, then runs fresh',
      () async {
    final a = _Adapter();
    final src = _src(1000);
    a.script.add(_Script(_rangeAware(src, etag: 'W/"v1"', lm: 'LM1'),
        chunkDelay: const Duration(milliseconds: 4), hangUntilCancelled: true));
    final d = dl(a);
    final tokenA = CancelToken();
    final fA = d.download(
        dio: dio(), directory: _dir, path: _path, cancelToken: tokenA);
    await Future<void>.delayed(const Duration(milliseconds: 8));
    tokenA.cancel();
    final fAOutcome = () async {
      try {
        await fA;
        return null;
      } catch (e) {
        return e;
      }
    }();
    await Future<void>.delayed(Duration.zero);
    a.script.add(_Script(_rangeAware(src, etag: 'W/"v1"', lm: 'LM1')));
    final fB = d.download(dio: dio(), directory: _dir, path: _path);
    final outcome = await fAOutcome;
    expect(outcome, isA<DioException>());
    expect((outcome as DioException).type, DioExceptionType.cancel);
    final rB = await fB;
    expect(a.requests, hasLength(2));
    expect(await rB.file.readAsBytes(), src);
  });

  test('sweep removes stale spool files, keeps fresh ones', () async {
    final a = _Adapter();
    final src = _src(1000);
    final dir = Directory('${tmp.path}/ob_download')
      ..createSync(recursive: true);
    final stale = File('${dir.path}/deadbeef.part')..writeAsStringSync('x');
    final staleMeta = File('${dir.path}/deadbeef.meta.json')
      ..writeAsStringSync('{}');
    final old = DateTime.now().subtract(const Duration(hours: 25));
    await stale.setLastModified(old);
    await staleMeta.setLastModified(old);
    a.script.add(_Script(_rangeAware(src, etag: 'W/"v1"', lm: 'LM1')));
    await dl(a).download(dio: dio(), directory: _dir, path: _path);
    var gone = false;
    for (var i = 0; i < 200 && !gone; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      gone = !stale.existsSync() && !staleMeta.existsSync();
    }
    expect(gone, true);
    expect(part().existsSync(), true);
  });

  test('real stack: fresh download then 416 reuse, identity on the wire',
      () async {
    final src = _src(4096);
    const etag = 'W/"42-abc"';
    const lm = 'Mon, 12 Oct 2026 00:00:00 GMT';
    final encodings = <String>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    unawaited(() async {
      await for (final req in server) {
        encodings.add(req.headers.value('accept-encoding') ?? '');
        final ifRange = req.headers.value(HttpHeaders.ifRangeHeader);
        final range = req.headers.value(HttpHeaders.rangeHeader);
        if (ifRange != null && ifRange != lm) {
          req.response
            ..statusCode = 200
            ..headers.contentLength = src.length
            ..headers.set('etag', etag)
            ..headers.set('last-modified', lm)
            ..add(src);
          await req.response.close();
          continue;
        }
        if (range != null) {
          final start = int.parse(range.substring(6, range.length - 1));
          if (start >= src.length) {
            req.response
              ..statusCode = 416
              ..headers.set('content-range', 'bytes */${src.length}');
            await req.response.close();
            continue;
          }
          final body = src.sublist(start);
          req.response
            ..statusCode = 206
            ..headers.contentLength = body.length
            ..headers.set(
                'content-range', 'bytes $start-${src.length - 1}/${src.length}')
            ..headers.set('etag', etag)
            ..headers.set('last-modified', lm)
            ..add(body);
          await req.response.close();
          continue;
        }
        req.response
          ..statusCode = 200
          ..headers.contentLength = src.length
          ..headers.set('etag', etag)
          ..headers.set('last-modified', lm)
          ..add(src);
        await req.response.close();
      }
    }());
    final c = OpencodeClient(
        Dio(BaseOptions(baseUrl: 'http://127.0.0.1:${server.port}')));
    final d = FileDownloader(tempDir: () async => tmp);
    final r1 = await d.download(dio: c.dio, directory: _dir, path: _path);
    expect(await r1.file.readAsBytes(), src);
    final r2 = await d.download(dio: c.dio, directory: _dir, path: _path);
    expect(r2.resumed, true);
    expect(await r2.file.readAsBytes(), src);
    expect(encodings, isNotEmpty);
    expect(encodings, everyElement('identity'));
  });

  test('smoke: localhost:15120 fresh + 416 reuse (skips when unreachable)',
      () async {
    const hostDir = '/home/cyrasafia/projects/my-tools/openbuilder';
    const filePath = 'AGENTS.md';
    final profile = ConnectionProfile(
      id: 't',
      name: 'test',
      address: 'http://localhost:15120',
      username: 'opencode',
      password: '1234321',
    );
    final smokeTmp = await Directory.systemTemp.createTemp('ob_dl_smoke');
    addTearDown(() => smokeTmp.delete(recursive: true));
    final d = FileDownloader(tempDir: () async => smokeTmp);
    final FileDownloadResult r1;
    try {
      r1 = await d.download(
          dio: dioFor(profile),
          directory: hostDir,
          path: filePath);
    } catch (e) {
      printOnFailure('server not reachable: $e');
      return;
    }
    expect(r1.total, greaterThan(0));
    expect(await r1.file.length(), r1.total);
    final r2 = await d.download(
        dio: dioFor(profile),
        directory: hostDir,
        path: filePath);
    expect(r2.resumed, true);
    expect(r2.total, r1.total);
  });
}
