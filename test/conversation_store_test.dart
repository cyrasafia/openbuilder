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

  group('lastMessagePreview hides reasoning when asked', () {
    test('reasoning-only last message: shown by default, null when hidden', () {
      final conv = ConversationStore('s6', _fakeClient());
      conv.onPartUpdated(
          <String, dynamic>{
            'messageID': 'm1',
            'id': 'r1',
            'type': 'reasoning',
          },
          'Let me think...');
      expect(conv.lastMessagePreview(), 'Let me think...');
      expect(conv.lastMessagePreview(hideReasoning: true), isNull);
    });

    test('reasoning as last part falls back to earlier text when hidden', () {
      final conv = ConversationStore('s7', _fakeClient());
      conv.onPartUpdated(
          <String, dynamic>{
            'messageID': 'm1',
            'id': 't1',
            'type': 'text',
          },
          'final answer');
      conv.onPartUpdated(
          <String, dynamic>{
            'messageID': 'm1',
            'id': 'r1',
            'type': 'reasoning',
          },
          'thinking out loud');
      // Default: reasoning is the last renderable part, so it wins.
      expect(conv.lastMessagePreview(), 'thinking out loud');
      // Hidden: reasoning skipped, falls back to the earlier text part.
      expect(conv.lastMessagePreview(hideReasoning: true), 'final answer');
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

  group('retry part error propagation', () {
    test('retry part propagates error to parent message info.error', () {
      final conv = ConversationStore('s8', _fakeClient());
      // Simulate a message updated (assistant message, no error yet).
      conv.onMessageUpdated(MessageInfo(
        id: 'msg_r1',
        role: 'assistant',
        sessionID: 's8',
        created: 1000,
      ));
      expect(conv.messages.single.info.error, isNull);

      // Simulate a retry part arriving with an APIError.
      conv.onPartUpdated({
        'id': 'prt_retry1',
        'messageID': 'msg_r1',
        'sessionID': 's8',
        'type': 'retry',
        'attempt': 1,
        'error': {
          'name': 'APIError',
          'data': {
            'message': 'Weekly/Monthly Limit Exhausted',
            'isRetryable': true,
          },
        },
        'time': {'created': 1001},
      }, null);

      // The retry part is hidden, so no parts added.
      expect(conv.messages.single.parts, isEmpty);
      // But the error is propagated to the message's info.error.
      final err = conv.messages.single.info.error;
      expect(err, isNotNull);
      expect(err!['name'], 'APIError');
      expect(err['data']['message'], 'Weekly/Monthly Limit Exhausted');
    });

    test('retry part does not overwrite existing message error', () {
      final conv = ConversationStore('s9', _fakeClient());
      conv.onMessageUpdated(MessageInfo(
        id: 'msg_r2',
        role: 'assistant',
        sessionID: 's9',
        created: 2000,
        error: {'name': 'ProviderAuthError', 'data': {'message': 'auth failed', 'providerID': 'openrouter'}},
      ));
      expect(conv.messages.single.info.error, isNotNull);

      conv.onPartUpdated({
        'id': 'prt_retry2',
        'messageID': 'msg_r2',
        'sessionID': 's9',
        'type': 'retry',
        'attempt': 1,
        'error': {'name': 'APIError', 'data': {'message': 'rate limit', 'isRetryable': true}},
        'time': {'created': 2001},
      }, null);

      // Original error preserved; retry error not overwritten.
      expect(conv.messages.single.info.error!['name'], 'ProviderAuthError');
    });

    test('empty retry error does not propagate', () {
      final conv = ConversationStore('s10', _fakeClient());
      conv.onMessageUpdated(MessageInfo(
        id: 'msg_r3',
        role: 'assistant',
        sessionID: 's10',
        created: 3000,
      ));

      conv.onPartUpdated({
        'id': 'prt_retry3',
        'messageID': 'msg_r3',
        'sessionID': 's10',
        'type': 'retry',
        'attempt': 1,
        'error': <String, dynamic>{},
        'time': {'created': 3001},
      }, null);

      expect(conv.messages.single.info.error, isNull);
    });

    test('message.updated preserves retry error when new info lacks error', () {
      final conv = ConversationStore('s11', _fakeClient());
      // 1. message.updated arrives first (no error).
      conv.onMessageUpdated(MessageInfo(
        id: 'msg_r4',
        role: 'assistant',
        sessionID: 's11',
        created: 4000,
      ));
      // 2. Retry part arrives, sets error on message.
      conv.onPartUpdated({
        'id': 'prt_retry4',
        'messageID': 'msg_r4',
        'sessionID': 's11',
        'type': 'retry',
        'attempt': 1,
        'error': {'name': 'APIError', 'data': {'message': 'rate limit', 'isRetryable': true}},
        'time': {'created': 4001},
      }, null);
      expect(conv.messages.single.info.error, isNotNull);

      // 3. Another message.updated arrives WITHOUT error (e.g., status bump).
      conv.onMessageUpdated(MessageInfo(
        id: 'msg_r4',
        role: 'assistant',
        sessionID: 's11',
        created: 4000,
        finish: 'error',
      ));
      // Retry error is preserved, not overwritten to null.
      expect(conv.messages.single.info.error!['name'], 'APIError');
    });
  });

  group('setStatus retry message', () {
    ConversationStore newConv() => ConversationStore('s12', _fakeClient());

    test('retry status stores message', () {
      final conv = newConv();
      conv.setStatus('retry', retryMessage: 'rate limit hit');
      expect(conv.status, 'retry');
      expect(conv.retryMessage, 'rate limit hit');
    });

    test('consecutive retry with empty message preserves last message', () {
      final conv = newConv();
      conv.setStatus('retry', retryMessage: 'rate limit hit');
      conv.setStatus('retry', retryMessage: null);
      expect(conv.retryMessage, 'rate limit hit');
      conv.setStatus('retry', retryMessage: '');
      expect(conv.retryMessage, 'rate limit hit');
      conv.setStatus('retry', retryMessage: 'auth failed');
      expect(conv.retryMessage, 'auth failed');
    });

    test('non-retry transition clears retryMessage', () {
      final conv = newConv();
      conv.setStatus('retry', retryMessage: 'rate limit hit');
      expect(conv.retryMessage, isNotNull);
      conv.setStatus('busy');
      expect(conv.retryMessage, isNull);
      conv.setStatus('retry', retryMessage: 'again');
      conv.setStatus('idle');
      expect(conv.retryMessage, isNull);
    });

    test('no notify when status and retryMessage unchanged', () {
      final conv = newConv();
      conv.setStatus('retry', retryMessage: 'rate limit hit');
      var notifies = 0;
      conv.addListener(() => notifies++);
      conv.setStatus('retry', retryMessage: 'rate limit hit');
      expect(notifies, 0);
      conv.setStatus('retry', retryMessage: null);
      expect(notifies, 0);
    });

    test('notifies when retryMessage changes', () {
      final conv = newConv();
      conv.setStatus('retry', retryMessage: 'rate limit hit');
      var notifies = 0;
      conv.addListener(() => notifies++);
      conv.setStatus('retry', retryMessage: 'auth failed');
      expect(notifies, 1);
      expect(conv.retryMessage, 'auth failed');
    });
  });

  group('synthetic text part filtering', () {
    test('shouldHidePartForTest hides synthetic text', () {
      expect(
        ConversationStore.shouldHidePartForTest(
            {'type': 'text', 'synthetic': true, 'text': 'file content'}),
        isTrue,
      );
    });

    test('shouldHidePartForTest keeps real text', () {
      expect(
        ConversationStore.shouldHidePartForTest(
            {'type': 'text', 'text': 'hello'}),
        isFalse,
      );
    });

    test('shouldHidePartForTest keeps file parts', () {
      expect(
        ConversationStore.shouldHidePartForTest(
            {'type': 'file', 'url': 'data:...', 'filename': 'a.txt'}),
        isFalse,
      );
    });

    test('toDisplayForTest filters synthetic text but keeps file + real text', () {
      final conv = ConversationStore('s_syn', _fakeClient());
      final dm = conv.toDisplayForTest(MessageEntry.fromJson({
        'info': {
          'id': 'msg_u1',
          'role': 'user',
          'time': {'created': 1000},
        },
        'parts': [
          {'id': 'prt1', 'type': 'text', 'text': 'check this file'},
          {'id': 'prt2', 'type': 'file', 'url': 'data:text/plain;base64,AA==',
           'filename': 'test.txt'},
          {'id': 'prt3', 'type': 'text', 'synthetic': true,
           'text': 'Called the Read tool with the following input: {"filePath":"test.txt"}'},
          {'id': 'prt4', 'type': 'text', 'synthetic': true,
           'text': 'file content here...'},
        ],
      }));
      expect(dm.parts.length, 2);
      expect(dm.parts[0].type, 'text');
      expect(dm.parts[0].text, 'check this file');
      expect(dm.parts[1].type, 'file');
      expect(dm.parts[1].filename, 'test.txt');
    });

    test('onPartUpdated skips synthetic text from SSE', () {
      final conv = ConversationStore('s_syn2', _fakeClient());
      conv.onMessageUpdated(MessageInfo(
        id: 'msg_u2', role: 'user', sessionID: 's_syn2', created: 2000));
      conv.onPartUpdated({
        'id': 'prt_real',
        'messageID': 'msg_u2',
        'type': 'text',
        'text': 'my message',
      }, null);
      conv.onPartUpdated({
        'id': 'prt_syn1',
        'messageID': 'msg_u2',
        'type': 'text',
        'text': 'Called the Read tool...',
        'synthetic': true,
      }, null);
      conv.onPartUpdated({
        'id': 'prt_syn2',
        'messageID': 'msg_u2',
        'type': 'text',
        'text': 'file content...',
        'synthetic': true,
      }, null);
      final msg = conv.messages.single;
      expect(msg.parts.length, 1);
      expect(msg.parts.single.type, 'text');
      expect(msg.parts.single.text, 'my message');
    });

    test('onPartUpdated keeps file parts from SSE', () {
      final conv = ConversationStore('s_syn3', _fakeClient());
      conv.onMessageUpdated(MessageInfo(
          id: 'msg_u3', role: 'user', sessionID: 's_syn3', created: 3000));
      conv.onPartUpdated({
        'id': 'prt_file',
        'messageID': 'msg_u3',
        'type': 'file',
        'url': 'data:image/png;base64,AAAA',
        'filename': 'pic.png',
      }, null);
      final msg = conv.messages.single;
      expect(msg.parts.length, 1);
      expect(msg.parts.single.type, 'file');
      expect(msg.parts.single.filename, 'pic.png');
    });

    // The server emits a synthetic user message ("The following tool was
    // executed by the user") for shell commands whose only part is hidden.
    // It must be hidden from rendering instead of producing an empty bubble.
    test('synthetic-only user message renders no empty bubble', () {
      final conv = ConversationStore('s_syn4', _fakeClient());
      conv.onMessageUpdated(MessageInfo(
          id: 'msg_u4', role: 'user', sessionID: 's_syn4', created: 4000));
      conv.onPartUpdated({
        'id': 'prt_shell',
        'messageID': 'msg_u4',
        'type': 'text',
        'text': 'The following tool was executed by the user',
        'synthetic': true,
      }, null);
      // The hidden part is skipped; the message stays in the store but is
      // excluded from rendering so no empty bubble appears.
      expect(conv.messages.single.info.id, 'msg_u4');
      expect(conv.messages.single.parts, isEmpty);
      expect(conv.renderableMessages, isEmpty);
    });

    // Regression: a hidden part arriving before a visible part must not drop
    // the user message or resurrect it with the wrong role.
    test('user message renders when visible part follows hidden part', () {
      final conv = ConversationStore('s_syn5', _fakeClient());
      conv.onMessageUpdated(MessageInfo(
          id: 'msg_u5', role: 'user', sessionID: 's_syn5', created: 5000));
      conv.onPartUpdated({
        'id': 'prt_syn',
        'messageID': 'msg_u5',
        'type': 'text',
        'text': 'synthetic echo',
        'synthetic': true,
      }, null);
      conv.onPartUpdated({
        'id': 'prt_real',
        'messageID': 'msg_u5',
        'type': 'text',
        'text': 'real message',
      }, null);
      expect(conv.renderableMessages.length, 1);
      final msg = conv.renderableMessages.single;
      expect(msg.info.role, 'user');
      expect(msg.parts.single.text, 'real message');
    });

    test('isEmptyUserForTest flags only non-optimistic empty user messages', () {
      final emptyUser = DisplayMessage(MessageInfo(id: 'x', role: 'user'));
      expect(ConversationStore.isEmptyUserForTest(emptyUser), isTrue);
      final userWithPart = DisplayMessage(MessageInfo(id: 'x', role: 'user'))
        ..parts.add(DisplayPart(id: 'p', type: 'text', text: 'hi'));
      expect(ConversationStore.isEmptyUserForTest(userWithPart), isFalse);
      final emptyAssistant = DisplayMessage(MessageInfo(id: 'x', role: 'assistant'));
      expect(ConversationStore.isEmptyUserForTest(emptyAssistant), isFalse);
      final optimisticEmpty =
          DisplayMessage(MessageInfo(id: 'x', role: 'user'), optimistic: true);
      expect(ConversationStore.isEmptyUserForTest(optimisticEmpty), isFalse);
    });
  });
}
