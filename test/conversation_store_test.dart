import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/core/attachments/attachment_pipeline.dart';
import 'package:open_builder/core/cache/cache_store.dart';
import 'package:open_builder/core/connection/connection_profile.dart';
import 'package:open_builder/core/net/dio_factory.dart';
import 'package:open_builder/core/net/net_error.dart';
import 'package:open_builder/core/session/conversation_store.dart';
import 'package:open_builder/data/api/opencode_client.dart';
import 'package:open_builder/domain/models.dart';
import 'package:open_builder/l10n/gen/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io';

import 'v2_test_fixtures.dart';

OpencodeClient _fakeClient() => OpencodeClient(dioFor(const ConnectionProfile(
      id: 't',
      name: 'test',
      address: 'http://127.0.0.1:9',
      username: 'opencode',
      password: '',
    )));

late CacheStore _cache;
late Directory _tmp;

ConversationStore _conv(String sid, OpencodeClient client,
        {String directory = ''}) =>
    ConversationStore(sid, client, directory: directory, cacheStore: _cache);

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _tmp = await Directory.systemTemp.createTemp('conv_test');
    FileCacheStore.rootBaseOverride = Directory('${_tmp.path}/ob_cache');
    _cache = FileCacheStore('test');
  });
  tearDown(() async {
    FileCacheStore.rootBaseOverride = null;
    if (await _tmp.exists()) await _tmp.delete(recursive: true);
  });
  group('user message file parts from wire (AT-4: 工厂不解码)', () {
    test('extracts mime from data url, name/uri verbatim', () {
      final conv = _conv('s0', _fakeClient());
      final d = conv.toDisplayForTest(userMsg(
        id: 'm_f1',
        text: 'see attached',
        files: [
          {
            'uri': 'data:image/png;base64,AAAA',
            'name': 'a.png',
          },
        ],
      ))!;
      expect(d.parts.length, 2);
      expect(d.parts[0].type, 'text');
      expect(d.parts[1].type, 'file');
      expect(d.parts[1].fileMime, 'image/png');
      expect(d.parts[1].fileUrl, 'data:image/png;base64,AAAA');
      expect(d.parts[1].filename, 'a.png');
    });

    test('http uri + no name', () {
      final conv = _conv('s0', _fakeClient());
      final d = conv.toDisplayForTest(userMsg(
        id: 'm_f2',
        text: 'x',
        files: [
          {'uri': 'https://example.com/x.pdf'},
        ],
      ))!;
      expect(d.parts[1].fileUrl, 'https://example.com/x.pdf');
      expect(d.parts[1].filename, isNull);
      expect(d.parts[1].fileMime, isNull);
    });

    test('file:// uri has no mime', () {
      final conv = _conv('s0', _fakeClient());
      final d = conv.toDisplayForTest(userMsg(
        id: 'm_f3',
        text: 'x',
        files: [
          {'uri': 'file:///x/docs/a.md', 'name': 'a.md'},
        ],
      ))!;
      expect(d.parts[1].fileMime, isNull);
      expect(d.parts[1].filename, 'a.md');
    });
  });

  group('addOptimisticUserMessage with attachments', () {
    test('text + file parts, previewThumb from AttachmentPreview', () {
      final conv = _conv('s1', _fakeClient());
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
      expect(msg.isUser, isTrue);
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
      final conv = _conv('s2', _fakeClient());
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

    test('plain text only', () {
      final conv = _conv('s3', _fakeClient());
      conv.addOptimisticUserMessage('plain');
      final msg = conv.messages.single;
      expect(msg.parts.length, 1);
      expect(msg.parts[0].type, 'text');
      expect(msg.parts[0].text, 'plain');
    });
  });

  group('lastMessagePreview hides reasoning when asked', () {
    test('reasoning-only last message: shown by default, null when hidden', () {
      final conv = _conv('s6', _fakeClient());
      conv.onStepStarted('m1');
      conv.onReasoningStarted('m1', 0);
      conv.onReasoningDelta('m1', 0, 'Let me think...');
      expect(conv.lastMessagePreview(), 'Let me think...');
      expect(conv.lastMessagePreview(hideReasoning: true), isNull);
    });

    test('reasoning as last part falls back to earlier text when hidden', () {
      final conv = _conv('s7', _fakeClient());
      conv.onStepStarted('m1');
      conv.onTextStarted('m1', 0);
      conv.onTextDelta('m1', 0, 'final answer');
      conv.onReasoningStarted('m1', 0);
      conv.onReasoningDelta('m1', 0, 'thinking out loud');
      expect(conv.lastMessagePreview(), 'thinking out loud');
      expect(conv.lastMessagePreview(hideReasoning: true), 'final answer');
    });
  });

  group('lastMessagePreview file fallback', () {
    final zh = lookupAppLocalizations(const Locale('zh'));
    final en = lookupAppLocalizations(const Locale('en'));

    test('pure attachment optimistic -> localized fallback when filename empty',
        () {
      final conv = _conv('s4', _fakeClient());
      conv.addOptimisticUserMessage('', attachments: [
        AttachmentPreview(
            mime: 'image/png',
            filename: '',
            dataUrl: 'data:image/png;base64,AAAA'),
      ]);
      expect(conv.lastMessagePreview(loc: zh), '你: [附件]');
      expect(conv.lastMessagePreview(loc: en), 'You: [Attachment]');
    });

    test('attachment with filename uses filename', () {
      final conv = _conv('s5', _fakeClient());
      conv.addOptimisticUserMessage('', attachments: [
        AttachmentPreview(
            mime: 'application/pdf',
            filename: 'doc.pdf',
            dataUrl: 'data:application/pdf;base64,YQ=='),
      ]);
      expect(conv.lastMessagePreview(loc: zh), '你: doc.pdf');
      expect(conv.lastMessagePreview(loc: en), 'You: doc.pdf');
    });
  });

  group('tool part error extraction', () {
    DisplayMessage displayWith(ToolContent tool) {
      final conv = _conv('s_tool', _fakeClient());
      return conv.toDisplayForTest(assistantMsg(
        id: 'm_tool',
        content: [tool],
        finish: 'stop',
      ))!;
    }

    test('error tool state extracts message', () {
      final d = displayWith(toolPart(
        id: 'c1',
        status: 'error',
        input: {'command': 'ls'},
        error: 'permission denied',
      ));
      final dp = d.parts.single;
      expect(dp.toolStatus, 'error');
      expect(dp.toolError, 'permission denied');
    });

    test('running tool state has no error', () {
      final d = displayWith(toolPart(
        id: 'c2',
        status: 'running',
        input: {'command': 'ls'},
      ));
      expect(d.parts.single.toolError, isNull);
    });

    test('onToolFailed carries error from SSE', () {
      final conv = _conv('s6', _fakeClient());
      conv.onStepStarted('m1');
      conv.onToolInputStarted('m1', 'c3', 'bash');
      conv.onToolFailed('m1', 'c3', {'type': 'x', 'message': 'network unreachable'});
      expect(conv.messages.length, 1);
      final part = conv.messages.single.parts.single;
      expect(part.toolStatus, 'error');
      expect(part.toolError, 'network unreachable');
    });

    test('onToolFailed does not clear toolError when error map empty', () {
      final conv = _conv('s6', _fakeClient());
      conv.onStepStarted('m1');
      conv.onToolInputStarted('m1', 'c4', 'bash');
      conv.onToolFailed('m1', 'c4', {'message': 'network unreachable'});
      conv.onToolFailed('m1', 'c4', const {'message': ''});
      expect(conv.messages.single.parts.single.toolError, 'network unreachable');
    });

    test('cache round-trip preserves toolError', () async {
      final conv = _conv('s7', PageMockClient(const []));
      conv.onStepStarted('m2');
      conv.onToolInputStarted('m2', 'c5', 'bash');
      conv.onToolFailed('m2', 'c5', {'message': 'disk full'});
      await conv.saveCacheForTest();

      final restored = _conv('s7', _fakeClient());
      await restored.loadCacheForTest();
      expect(restored.messages.length, 1);
      expect(restored.messages.single.parts.single.toolError, 'disk full');
    });
  });

  group('form reply (v2 session-scoped)', () {
    test('setDirectory fills only when current is empty', () {
      final conv = _conv('s_q', _fakeClient());
      expect(conv.directory, '');
      conv.setDirectory('/a');
      expect(conv.directory, '/a');
      conv.setDirectory('/b');
      expect(conv.directory, '/a');
    });

    test('onForm adds pending and dedupes identical', () {
      final conv = _conv('s_q', _fakeClient());
      final f = formInfo(
        id: 'frm_1',
        sessionID: 's_q',
        fields: [selectField('choice', options: [option('yes', 'Yes')])],
      );
      conv.onForm(f);
      expect(conv.forms.length, 1);
      var notified = 0;
      conv.addListener(() => notified++);
      conv.onForm(formInfo(
        id: 'frm_1',
        sessionID: 's_q',
        fields: [selectField('choice', options: [option('yes', 'Yes')])],
      ));
      expect(conv.forms.length, 1);
      expect(notified, 0);
    });

    test('onFormReplied removes card', () {
      final conv = _conv('s_q', _fakeClient());
      conv.onForm(formInfo(id: 'frm_2', sessionID: 's_q'));
      expect(conv.forms.length, 1);
      conv.onFormReplied('frm_2');
      expect(conv.forms, isEmpty);
    });

    test('settled form (state answered) is not injected', () {
      final conv = _conv('s_q', _fakeClient());
      conv.onForm(formInfo(id: 'frm_3', sessionID: 's_q', stateStatus: 'answered'));
      expect(conv.forms, isEmpty);
    });
  });

  group('retry scheduled error propagation', () {
    test('retry.scheduled propagates error to message error', () {
      final conv = _conv('s6', _fakeClient());
      conv.onStepStarted('m1');
      conv.onRetryScheduled('m1', 1, {'message': 'provider 502'});
      expect(conv.isRetry, isTrue);
      expect(conv.retryMessage, 'provider 502');
      expect(conv.messages.single.error, isNotNull);
      expect(conv.messages.single.error!['message'], 'provider 502');
    });

    test('retry.scheduled does not overwrite existing message error', () {
      final conv = _conv('s6', _fakeClient());
      conv.onStepStarted('m1');
      conv.onStepFailed('m1', {'message': 'original failure'});
      conv.onRetryScheduled('m1', 1, {'message': 'provider 502'});
      expect(conv.messages.single.error!['message'], 'original failure');
    });

    test('empty retry error does not set message error', () {
      final conv = _conv('s6', _fakeClient());
      conv.onStepStarted('m1');
      conv.onRetryScheduled('m1', 1, const {'message': ''});
      expect(conv.messages.single.error, isNull);
      expect(conv.isRetry, isTrue);
    });
  });

  group('setStatus retry message', () {
    test('retry status stores message', () {
      final conv = _conv('s', _fakeClient());
      conv.setStatus('retry', retryMessage: 'boom');
      expect(conv.retryMessage, 'boom');
      expect(conv.isRetry, isTrue);
    });

    test('consecutive retry with empty message preserves last message', () {
      final conv = _conv('s', _fakeClient());
      conv.setStatus('retry', retryMessage: 'boom');
      conv.setStatus('retry');
      expect(conv.retryMessage, 'boom');
    });

    test('non-retry transition clears retryMessage', () {
      final conv = _conv('s', _fakeClient());
      conv.setStatus('retry', retryMessage: 'boom');
      conv.setStatus('idle');
      expect(conv.retryMessage, isNull);
    });

    test('no notify when status and retryMessage unchanged', () {
      final conv = _conv('s', _fakeClient());
      conv.setStatus('retry', retryMessage: 'boom');
      var notified = 0;
      conv.addListener(() => notified++);
      conv.setStatus('retry', retryMessage: 'boom');
      expect(notified, 0);
    });

    test('notifies when retryMessage changes', () {
      final conv = _conv('s', _fakeClient());
      conv.setStatus('retry', retryMessage: 'a');
      var notified = 0;
      conv.addListener(() => notified++);
      conv.setStatus('retry', retryMessage: 'b');
      expect(notified, 1);
    });
  });

  group('empty user message filtering', () {
    test('toDisplayForTest builds empty text part for empty user text', () {
      final conv = _conv('s', _fakeClient());
      final d = conv.toDisplayForTest(userMsg(id: 'm_e', text: ''))!;
      expect(d.parts.length, 1);
      expect(d.parts[0].type, 'text');
    });

    test('isEmptyUserForTest flags only non-optimistic empty user messages', () {
      final conv = _conv('s', _fakeClient());
      final emptyUser = conv.toDisplayForTest(userMsg(id: 'm_e', text: ''))!;
      expect(ConversationStore.isEmptyUserForTest(emptyUser), isTrue);

      final withText = conv.toDisplayForTest(userMsg(id: 'm_t', text: 'hi'))!;
      expect(ConversationStore.isEmptyUserForTest(withText), isFalse);

      final assistant = conv.toDisplayForTest(assistantMsg(id: 'm_a'))!;
      expect(ConversationStore.isEmptyUserForTest(assistant), isFalse);
    });

    test('whitespace-only text message renders no empty bubble', () {
      final conv = _conv('s', _fakeClient());
      final d = conv.toDisplayForTest(userMsg(id: 'm_w', text: '   '))!;
      expect(ConversationStore.isEmptyUserForTest(d), isTrue);
    });

    test('file-only user message is not empty', () {
      final conv = _conv('s', _fakeClient());
      final d = conv.toDisplayForTest(userMsg(
        id: 'm_f',
        text: '',
        files: [
          {'uri': 'data:image/png;base64,AAAA', 'name': 'a.png'},
        ],
      ))!;
      expect(ConversationStore.isEmptyUserForTest(d), isFalse);
    });
  });

  group('draft persistence (CD-1~31)', () {
    test('setDraft updates memory only and does not notify', () {
      final conv = _conv('s', _fakeClient());
      var notified = 0;
      conv.addListener(() => notified++);
      conv.setDraft('hello');
      expect(conv.draftText, 'hello');
      expect(notified, 0);
    });

    test('persistDraft writes draft/draftShell into blob', () async {
      final conv = _conv('s1', _fakeClient());
      conv.setDraft('typing', shell: true);
      await conv.persistDraft();

      final restored = _conv('s1', _fakeClient());
      await restored.loadDraftOnly();
      expect(restored.draftText, 'typing');
      expect(restored.draftShell, isTrue);
    });

    test('loadDraftOnly reads only draft, ignores messages (CD-1)', () async {
      final conv = _conv('s2', PageMockClient(const []));
      conv.onStepStarted('m1');
      conv.onTextDelta('m1', 0, 'streamed body');
      await conv.persistDraft();
      conv.setDraft('');

      final restored = _conv('s2', _fakeClient());
      await restored.loadDraftOnly();
      expect(restored.draftText, '');
      expect(restored.messages, isEmpty);
    });

    test('loadDraftOnly on missing blob sets draftLoaded without throw', () async {
      final conv = _conv('s_none', _fakeClient());
      await conv.loadDraftOnly();
      expect(conv.draftLoaded, isTrue);
    });

    test('loadDraftOnly notifies on completion (reactive restore, §5.3)',
        () async {
      final conv = _conv('s3', _fakeClient());
      conv.setDraft('keep');
      await conv.persistDraft();

      final restored = _conv('s3', _fakeClient());
      var notified = 0;
      restored.addListener(() => notified++);
      await restored.loadDraftOnly();
      expect(notified, 1);
      expect(restored.draftText, 'keep');
    });
  });

  group('optimistic→authoritative bridging', () {
    test('reconcile supersedes a pending optimistic user message (no double echo)',
        () async {
      final entries = [userMsg(id: 'msg_real_1', text: 'hello', created: 1000)];
      final conv = _conv('s1', PageMockClient(entries));
      conv.addOptimisticUserMessage('hello');
      await conv.reconcile();
      final r = conv.renderableMessages;
      expect(r.length, 1,
          reason: 'REST snapshot must replace the optimistic copy — both '
              'in flight rendered the message twice');
      expect(r.single.id, 'msg_real_1');
    });

    test('reconcile replaces optimistic copies one-for-one (FIFO, multiple sends)',
        () async {
      final entries = [
        userMsg(id: 'msg_real_1', text: 'first', created: 1000),
        userMsg(id: 'msg_real_2', text: 'second', created: 2000),
      ];
      final conv = _conv('s1', PageMockClient(entries));
      conv.addOptimisticUserMessage('first');
      conv.addOptimisticUserMessage('second');
      await conv.reconcile();
      expect(conv.renderableMessages.length, 2);
      expect(conv.renderableMessages.map((m) => m.id),
          containsAll(['msg_real_1', 'msg_real_2']));
      expect(conv.messages.any((m) => m.optimistic), isFalse);
    });

    test('reconcile keeps an optimistic message when the snapshot lags',
        () async {
      // The authoritative user message is not on the server yet (steer
      // delivery in flight): the optimistic copy must survive, not be
      // dropped by an unrelated older-entry upsert.
      final entries = [
        assistantMsg(
            id: 'msg_old_a', created: 500, content: [textPart('old')], finish: 'stop'),
      ];
      final conv = _conv('s1', PageMockClient(entries));
      conv.addOptimisticUserMessage('not yet delivered');
      await conv.reconcile();
      expect(conv.renderableMessages.length, 2,
          reason: 'snapshot lacks the sent message — optimistic copy stays');
      expect(conv.messages.any((m) => m.optimistic), isTrue);
    });

    test('inbox.enqueued(user) replaces optimistic and bridges file parts',
        () {
      final conv = _conv('s1', _fakeClient());
      conv.addOptimisticUserMessage('hi', attachments: [
        AttachmentPreview(
          mime: 'image/png',
          filename: 'a.png',
          dataUrl: 'data:image/png;base64,AAAA',
        ),
      ]);
      conv.onInboxEnqueued('msg_real_1', {
        'type': 'user',
        'payload': {'text': 'hi'},
      });
      expect(conv.messages.length, 1);
      final msg = conv.messages.single;
      expect(msg.id, 'msg_real_1');
      expect(msg.optimistic, isFalse);
      expect(msg.parts.where((p) => p.type == 'file').length, 1);
      expect(msg.parts.where((p) => p.type == 'file').single.fileUrl,
          'data:image/png;base64,AAAA');
    });

    test('authoritative files in payload evict placeholders 1:1', () {
      final conv = _conv('s2', _fakeClient());
      conv.addOptimisticUserMessage('', attachments: [
        AttachmentPreview(
            mime: 'image/png',
            filename: 'a.png',
            dataUrl: 'data:image/png;base64,AAAA'),
      ]);
      conv.onInboxEnqueued('msg_real_2', {
        'type': 'user',
        'payload': {
          'text': '',
          'files': [
            {'uri': 'data:image/png;base64,AAAA', 'name': 'a.png'},
          ],
        },
      });
      final files = conv.messages.single.parts.where((p) => p.type == 'file');
      expect(files.length, 1);
    });

    test('bridges oldest (FIFO) optimistic when multiple sends are pending',
        () {
      final conv = _conv('s3', _fakeClient());
      conv.addOptimisticUserMessage('first');
      conv.addOptimisticUserMessage('second');
      conv.onInboxEnqueued('msg_real_3', {
        'type': 'user',
        'payload': {'text': 'first'},
      });
      expect(conv.messages.length, 1);
      expect(conv.messages.single.id, 'msg_real_3');
      expect(conv.messages.single.parts.first.text, 'first');
    });
  });

  group('message content updated (authoritative parts)', () {
    test('content.updated replaces parts of existing message', () {
      final conv = _conv('s1', _fakeClient());
      conv.onStepStarted('m1');
      conv.onTextStarted('m1', 0);
      conv.onTextDelta('m1', 0, 'partial');
      conv.onMessageContentUpdated('m1', [textPart('authoritative text')]);
      expect(conv.messages.single.parts.where((p) => p.type == 'text').single.text,
          'authoritative text');
    });

    test('content.updated for unknown message inserts it', () {
      final conv = _conv('s2', _fakeClient());
      conv.onMessageContentUpdated('m_new', [textPart('fresh')]);
      expect(conv.messages.single.id, 'm_new');
      expect(conv.messages.single.parts.single.text, 'fresh');
    });
  });

  group('streaming part ordering (multi-step messages)', () {
    test('parts append in started-event arrival order, not by kind', () {
      final conv = _conv('s1', _fakeClient());
      conv.onStepStarted('m1');
      conv.onReasoningStarted('m1', 0);
      conv.onReasoningDelta('m1', 0, 'think 1');
      conv.onTextStarted('m1', 0);
      conv.onTextDelta('m1', 0, 'answer 1');
      conv.onToolInputStarted('m1', 'c1', 'bash');
      // Second step: new reasoning + text parts for the SAME message.
      conv.onReasoningStarted('m1', 1);
      conv.onReasoningDelta('m1', 1, 'think 2');
      conv.onTextStarted('m1', 1);
      conv.onTextDelta('m1', 1, 'answer 2');
      final types = conv.messages.single.parts.map((p) => p.type).toList();
      expect(types, [
        'reasoning',
        'text',
        'tool',
        'reasoning',
        'text',
      ], reason: 'streaming parts must follow content order, '
          'not cluster by kind');
    });
  });

  group('step finish lifecycle', () {
    test('step boundary with tool-calls does not persist a settled message',
        () async {
      final conv = _conv('s1', _fakeClient());
      conv.onStepStarted('m1');
      conv.onTextDelta('m1', 0, 'calling tools');
      conv.onStepEnded('m1', finish: 'tool-calls');
      expect(conv.messages.single.finish, 'tool-calls');
      // Continuation step: finish must be cleared so streaming resumes.
      conv.onStepStarted('m1');
      expect(conv.messages.single.finish, isNull);
      conv.onTextDelta('m1', 1, 'final answer');
      conv.onStepEnded('m1', finish: 'stop');
      expect(conv.messages.single.finish, 'stop');
      // A terminal finish is not cleared by a stray later step event.
      conv.onStepStarted('m1');
      expect(conv.messages.single.finish, 'stop');
    });
  });

  group('cache round-trip preserves file fields', () {
    test('user message with files survives save/load', () async {
      final conv = _conv('s1', PageMockClient(const []));
      conv.onInboxEnqueued('msg_f1', {
        'type': 'user',
        'payload': {
          'text': 'see',
          'files': [
            {'uri': 'data:image/png;base64,AAAA', 'name': 'a.png'},
          ],
        },
      });
      await conv.saveCacheForTest();

      final restored = _conv('s1', _fakeClient());
      await restored.loadCacheForTest();
      final msg = restored.messages.single;
      expect(msg.isUser, isTrue);
      final file = msg.parts.where((p) => p.type == 'file').single;
      expect(file.fileUrl, 'data:image/png;base64,AAAA');
      expect(file.filename, 'a.png');
      expect(file.fileMime, 'image/png');
    });
  });

  group('offline cache restore settles unfinished assistant message', () {
    test('terminal load injects finish stop for streaming message', () async {
      final conv = _conv('s1', PageMockClient(const []));
      conv.onStepStarted('m1');
      conv.onTextStarted('m1', 0);
      conv.onTextDelta('m1', 0, 'half streamed');
      await conv.saveCacheForTest();

      final restored = _conv('s1', _fakeClient());
      await restored.loadCacheForTest();
      final msg = restored.messages.single;
      expect(msg.isAssistant, isTrue);
      expect(msg.finish, 'stop');
      expect(msg.parts.single.text, 'half streamed');
    });

    test('preheat restore keeps unfinished assistant message streaming',
        () async {
      final conv = _conv('s1', PageMockClient(const []));
      conv.sessionUpdated = 42;
      conv.onStepStarted('m1');
      conv.onTextDelta('m1', 0, 'streaming now');
      await conv.saveCacheForTest();

      final restored = _conv('s1', _fakeClient());
      restored.sessionUpdated = 42;
      await restored.preheatCacheForTest();
      final msg = restored.messages.single;
      expect(msg.finish, isNull);
      expect(msg.parts.single.text, 'streaming now');
    });
  });

  group('todos derived from todowrite tool calls', () {
    test('latest todowrite input wins', () {
      final conv = _conv('s1', _fakeClient());
      conv.onStepStarted('m1');
      conv.onToolInputStarted('m1', 'c1', 'todowrite');
      conv.onToolCalled('m1', 'c1', {
        'todos': [
          {'content': 'step a', 'status': 'in_progress'},
          {'content': 'step b', 'status': 'pending'},
        ],
      }, null);
      expect(conv.todos.length, 2);
      expect(conv.todos.first.content, 'step a');
      expect(conv.todos.first.active, isTrue);

      conv.onToolInputStarted('m1', 'c2', 'todowrite');
      conv.onToolCalled('m1', 'c2', {
        'todos': [
          {'content': 'step a', 'status': 'completed'},
          {'content': 'step b', 'status': 'in_progress'},
        ],
      }, null);
      expect(conv.todos.length, 2);
      expect(conv.todos.first.done, isTrue);
      expect(conv.todos[1].active, isTrue);
    });

    test('no todowrite leaves todos empty', () {
      final conv = _conv('s2', _fakeClient());
      conv.onStepStarted('m1');
      conv.onToolInputStarted('m1', 'c1', 'bash');
      conv.onToolCalled('m1', 'c1', {'command': 'ls'}, null);
      expect(conv.todos, isEmpty);
    });

    test('todowrite without todos key is ignored', () {
      final conv = _conv('s3', _fakeClient());
      conv.onStepStarted('m1');
      conv.onToolInputStarted('m1', 'c1', 'todowrite');
      conv.onToolCalled('m1', 'c1', const {}, null);
      expect(conv.todos, isEmpty);
    });
  });

  group('oversized page terminal handling', () {
    test('MessagePageTooLargeException is terminal: error kept, no retry loop',
        () async {
      final client = _TooLargeClient();
      final conv = _conv('s1', client);
      addTearDown(conv.dispose);
      await conv.load();
      expect(client.calls, 1);
      expect(conv.error, isA<MessagePageTooLargeException>());
      expect(conv.loading, isFalse,
          reason: 'terminal error must clear the loading spinner');
      expect(conv.isStale, isFalse,
          reason: 'page size is permanent — stale-driven reloads must stop');
      await conv.reloadIfStale();
      expect(client.calls, 1, reason: 'no stale-driven re-fetch after terminal');
    });

    test('transport errors keep the stale/retry path', () async {
      final client = _FailClient();
      final conv = _conv('s1', client);
      addTearDown(conv.dispose);
      await conv.load();
      expect(conv.error, isNotNull);
      expect(conv.isStale, isTrue);
    });
  });
}

class _TooLargeClient extends OpencodeClient {
  int calls = 0;
  _TooLargeClient()
      : super(Dio(BaseOptions(
          connectTimeout: const Duration(milliseconds: 1),
          receiveTimeout: const Duration(milliseconds: 1),
        )));

  @override
  Future<MessagesPage> messagesPageCompute(String sessionId,
      {required int limit, String? cursor}) async {
    calls++;
    throw const MessagePageTooLargeException(
        size: 99999999, limit: 8388608, sessionId: 's1');
  }
}

class _FailClient extends OpencodeClient {
  _FailClient()
      : super(Dio(BaseOptions(
          connectTimeout: const Duration(milliseconds: 1),
          receiveTimeout: const Duration(milliseconds: 1),
        )));

  @override
  Future<MessagesPage> messagesPageCompute(String sessionId,
      {required int limit, String? cursor}) async {
    throw DioException(
        requestOptions: RequestOptions(path: '/x'),
        type: DioExceptionType.connectionError);
  }
}
