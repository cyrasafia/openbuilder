import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/core/attachments/attachment_pipeline.dart';
import 'package:open_builder/core/connection/connection_profile.dart';
import 'package:open_builder/core/net/dio_factory.dart';
import 'package:open_builder/core/session/conversation_store.dart';
import 'package:open_builder/data/api/opencode_client.dart';
import 'package:open_builder/domain/models.dart';

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
}
