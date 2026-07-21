import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/core/attachments/attachment_pipeline.dart';
import 'package:open_builder/core/connection/connection_profile.dart';
import 'package:open_builder/core/net/dio_factory.dart';
import 'package:open_builder/core/session/conversation_store.dart';
import 'package:open_builder/data/api/opencode_client.dart';
import 'package:open_builder/domain/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

// 指向丢弃端口的非空 client；被测逻辑（addOptimisticUserMessage /
// lastMessagePreview / DisplayPart.from）均不发起网络请求。
OpencodeClient _fakeClient() => OpencodeClient(dioFor(const ConnectionProfile(
      id: 't',
      name: 'test',
      address: 'http://127.0.0.1:9',
      username: 'opencode',
      password: '',
    )));

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });
  group('DisplayPart.from file branch (AT-4: 工厂不解码)', () {
    test('extracts mime/url/filename, previewThumb null', () {
      final dp = DisplayPart.from(MessagePart({
        'id': 'f1',
        'type': 'file',
        'mime': 'image/png',
        'url': 'data:image/png;base64,AAAA',
        'filename': 'a.png',
      }));
      expect(dp.type, 'file');
      expect(dp.fileMime, 'image/png');
      expect(dp.fileUrl, 'data:image/png;base64,AAAA');
      expect(dp.filename, 'a.png');
      expect(dp.previewThumb, isNull);
    });

    test('http url + no filename', () {
      final dp = DisplayPart.from(MessagePart({
        'id': 'f2',
        'type': 'file',
        'mime': 'application/pdf',
        'url': 'https://example.com/x.pdf',
      }));
      expect(dp.fileMime, 'application/pdf');
      expect(dp.fileUrl, 'https://example.com/x.pdf');
      expect(dp.filename, isNull);
      expect(dp.previewThumb, isNull);
    });

    test('missing url defaults to empty string', () {
      final dp = DisplayPart.from(
          MessagePart({'id': 'f3', 'type': 'file', 'mime': 'image/png'}));
      expect(dp.fileUrl, '');
    });
  });

  group('addOptimisticUserMessage with attachments', () {
    test('text + file parts, previewThumb from AttachmentPreview', () {
      final conv = ConversationStore('s1', _fakeClient());
      final thumb = Uint8List.fromList([1, 2, 3]);
      conv.addOptimisticUserMessage('hi', attachments: [
        AttachmentPreview(
          mime: 'image/png',
          filename: 'a.png',
          dataUrl: 'data:image/png;base64,AAAA',
          previewThumb: thumb,
        ),
      ]);
      expect(conv.messages.length, 1);
      final msg = conv.messages.single;
      expect(msg.info.role, 'user');
      expect(msg.optimistic, isTrue);
      expect(msg.parts.length, 2);
      expect(msg.parts[0].type, 'text');
      expect(msg.parts[0].text, 'hi');
      expect(msg.parts[1].type, 'file');
      expect(msg.parts[1].fileMime, 'image/png');
      expect(msg.parts[1].fileUrl, 'data:image/png;base64,AAAA');
      expect(msg.parts[1].filename, 'a.png');
      expect(msg.parts[1].previewThumb, thumb);
    });

    test('pure attachments (no text) produces only file parts', () {
      final conv = ConversationStore('s2', _fakeClient());
      conv.addOptimisticUserMessage('', attachments: [
        AttachmentPreview(
            mime: 'application/pdf',
            filename: 'x.pdf',
            dataUrl: 'data:application/pdf;base64,YQ=='),
      ]);
      final msg = conv.messages.single;
      expect(msg.parts.length, 1);
      expect(msg.parts[0].type, 'file');
      expect(msg.parts[0].filename, 'x.pdf');
    });

    test('backward compat: single-arg still works', () {
      final conv = ConversationStore('s3', _fakeClient());
      conv.addOptimisticUserMessage('plain');
      final msg = conv.messages.single;
      expect(msg.parts.length, 1);
      expect(msg.parts[0].type, 'text');
      expect(msg.parts[0].text, 'plain');
    });
  });

  group('lastMessagePreview file fallback', () {
    test('pure attachment optimistic -> [附件] when filename empty', () {
      final conv = ConversationStore('s4', _fakeClient());
      conv.addOptimisticUserMessage('', attachments: [
        AttachmentPreview(
            mime: 'image/png',
            filename: '',
            dataUrl: 'data:image/png;base64,AAAA'),
      ]);
      expect(conv.lastMessagePreview(), '你: [附件]');
    });

    test('attachment with filename uses filename', () {
      final conv = ConversationStore('s5', _fakeClient());
      conv.addOptimisticUserMessage('', attachments: [
        AttachmentPreview(
            mime: 'application/pdf',
            filename: 'doc.pdf',
            dataUrl: 'data:application/pdf;base64,YQ=='),
      ]);
      expect(conv.lastMessagePreview(), '你: doc.pdf');
    });
  });

  // Error display coverage: tool part state.error extraction + persistence.
  group('tool part error extraction', () {
    test('extracts string error from state.error', () {
      final dp = DisplayPart.from(MessagePart({
        'id': 'p1',
        'type': 'tool',
        'tool': 'bash',
        'state': {
          'status': 'error',
          'input': {'command': 'ls'},
          'error': 'permission denied',
        },
      }));
      expect(dp.toolStatus, 'error');
      expect(dp.toolError, 'permission denied');
    });

    test('extracts message from structured error object', () {
      final dp = DisplayPart.from(MessagePart({
        'id': 'p2',
        'type': 'tool',
        'tool': 'bash',
        'state': {
          'status': 'error',
          'input': {'command': 'ls'},
          'error': {'type': 'unknown', 'message': 'exec failed'},
        },
      }));
      expect(dp.toolError, 'exec failed');
    });

    test('toolError null when state.error missing', () {
      final dp = DisplayPart.from(MessagePart({
        'id': 'p3',
        'type': 'tool',
        'tool': 'bash',
        'state': {
          'status': 'running',
          'input': {'command': 'ls'},
        },
      }));
      expect(dp.toolError, isNull);
    });

    test('onPartUpdated carries error from SSE', () {
      final conv = ConversationStore('s6', _fakeClient());
      conv.onPartUpdated({
        'id': 'p4',
        'messageID': 'm1',
        'type': 'tool',
        'tool': 'bash',
        'state': {
          'status': 'error',
          'input': {'command': 'ls'},
          'error': 'network unreachable',
        },
      }, null);
      expect(conv.messages.length, 1);
      final part = conv.messages.single.parts.single;
      expect(part.toolStatus, 'error');
      expect(part.toolError, 'network unreachable');
    });

    test('onPartUpdated does not clear toolError when later state omits error', () {
      final conv = ConversationStore('s6', _fakeClient());
      conv.onPartUpdated({
        'id': 'p4',
        'messageID': 'm1',
        'type': 'tool',
        'tool': 'bash',
        'state': {
          'status': 'error',
          'input': {'command': 'ls'},
          'error': 'network unreachable',
        },
      }, null);
      // A later update that repeats status but omits error should not wipe the text.
      conv.onPartUpdated({
        'id': 'p4',
        'messageID': 'm1',
        'type': 'tool',
        'tool': 'bash',
        'state': {
          'status': 'error',
          'input': {'command': 'ls'},
        },
      }, null);
      expect(conv.messages.single.parts.single.toolError, 'network unreachable');
    });

    test('cache round-trip preserves toolError', () async {
      final conv = ConversationStore('s7', _fakeClient());
      conv.onPartUpdated({
        'id': 'p5',
        'messageID': 'm2',
        'type': 'tool',
        'tool': 'bash',
        'state': {
          'status': 'error',
          'input': {'command': 'ls'},
          'error': 'disk full',
        },
      }, null);
      await conv.saveCacheForTest();

      final restored = ConversationStore('s7', _fakeClient());
      await restored.loadCacheForTest();
      expect(restored.messages.length, 1);
      expect(restored.messages.single.parts.single.toolError, 'disk full');
    });
  });

  // M-1 覆盖：directory 空边界 + setDirectory 回填语义。
  group('question reply directory guard (M-1)', () {
    final q = QuestionRequest(
        id: 'que_t1', sessionID: 's1', questions: const []);

    test('replyQuestion throws when directory empty and keeps the card', () async {
      final conv = ConversationStore('s1', _fakeClient()); // directory 默认 ''
      expect(conv.directory, '');
      conv.onQuestion(q);
      expect(conv.questions.length, 1);
      await expectLater(
        conv.replyQuestion(q, const [
          ['a']
        ]),
        throwsA(isA<StateError>()),
      );
      // 抛错前不移除卡片：用户可重试。
      expect(conv.questions.length, 1);
    });

    test('rejectQuestion throws when directory empty and keeps the card', () async {
      final conv = ConversationStore('s1', _fakeClient());
      conv.onQuestion(q);
      await expectLater(conv.rejectQuestion(q), throwsA(isA<StateError>()));
      expect(conv.questions.length, 1);
    });

    test('setDirectory fills only when current is empty', () {
      final conv = ConversationStore('s1', _fakeClient());
      expect(conv.directory, '');
      conv.setDirectory('/a');
      expect(conv.directory, '/a');
      // 非空时不覆盖（避免回填覆盖已注入的有效值）。
      conv.setDirectory('/b');
      expect(conv.directory, '/a');
      // 空 dir 永不填充。
      conv.setDirectory('');
      expect(conv.directory, '/a');
    });
  });
}
