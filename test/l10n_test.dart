import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/l10n/gen/app_localizations.dart';

// P7 (plan-i18n §P7 item 3): guard the i18n surface so a future ARB edit can't
// silently drop a key. gen-l10n warns on a missing key, but a divergent key set
// between locales or an accidental zh-copy-into-en would only surface at runtime
// (null label / English-user-sees-Chinese). Three concerns are covered:
//   1. zh / en ARB key sets are identical (no untranslated key either way).
//   2. A representative sample of high-traffic getters resolve to non-empty
//      strings in BOTH locales (catches a getter returning '' from a bad ARB
//      entry).
//   3. en values are not accidentally copies of zh for CJK-bearing keys.
// (AppLocalizations is a typed abstract class — no reflective field access in
// Flutter, so critical keys are asserted via their typed getters directly.)

const _arbZh = 'lib/l10n/app_zh.arb';
const _arbEn = 'lib/l10n/app_en.arb';

Set<String> _keys(String path) {
  final raw = jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
  return raw.keys.where((k) => !k.startsWith('@')).toSet();
}

bool _hasCjk(String s) => RegExp(r'[\u4e00-\u9fff]').hasMatch(s);

void main() {
  final zh = lookupAppLocalizations(const Locale('zh'));
  final en = lookupAppLocalizations(const Locale('en'));

  group('ARB key parity', () {
    test('zh and en declare the same key set', () {
      final z = _keys(_arbZh);
      final e = _keys(_arbEn);
      expect(z.difference(e), isEmpty, reason: 'keys only in zh');
      expect(e.difference(z), isEmpty, reason: 'keys only in en');
      expect(z.length, e.length);
    });
  });

  group('critical getters resolve non-empty in both locales', () {
    // A cross-cutting sample covering errors / nav / settings / conversation /
    // files / notifications / plurals. Each entry is (zh, en) for one getter.
    final samples = <(String, String, String)>[
      ('errorAuthFailed', zh.errorAuthFailed, en.errorAuthFailed),
      ('errorSessionNotReady', zh.errorSessionNotReady, en.errorSessionNotReady),
      ('errorNotConnected', zh.errorNotConnected, en.errorNotConnected),
      ('errorGeneric', zh.errorGeneric, en.errorGeneric),
      ('tabSessions', zh.tabSessions, en.tabSessions),
      ('tabProjects', zh.tabProjects, en.tabProjects),
      ('tabSettings', zh.tabSettings, en.tabSettings),
      ('settingsTitle', zh.settingsTitle, en.settingsTitle),
      ('settingsLanguage', zh.settingsLanguage, en.settingsLanguage),
      ('systemLanguage', zh.systemLanguage, en.systemLanguage),
      ('loadFailed', zh.loadFailed, en.loadFailed),
      ('retry', zh.retry, en.retry),
      ('cancel', zh.cancel, en.cancel),
      ('convDefaultTitle', zh.convDefaultTitle, en.convDefaultTitle),
      ('previewYouPrefix', zh.previewYouPrefix, en.previewYouPrefix),
      ('attachmentFallback', zh.attachmentFallback, en.attachmentFallback),
      ('permissionRequest', zh.permissionRequest, en.permissionRequest),
      ('permissionAllowOnce', zh.permissionAllowOnce, en.permissionAllowOnce),
      ('notifRunCompleteBody', zh.notifRunCompleteBody('x'),
          en.notifRunCompleteBody('x')),
      ('notifPermissionTitle', zh.notifPermissionTitle, en.notifPermissionTitle),
      ('notifQuestionTitle', zh.notifQuestionTitle, en.notifQuestionTitle),
      ('projectMainWorkspace', zh.projectMainWorkspace, en.projectMainWorkspace),
      ('modelsHideHint', zh.modelsHideHint(1, 2), en.modelsHideHint(1, 2)),
      ('welcomeIntro', zh.welcomeIntro, en.welcomeIntro),
      ('webBasicAuthBody', zh.webBasicAuthBody, en.webBasicAuthBody),
    ];

    for (final (name, z, e) in samples) {
      test('$name non-empty in zh and en', () {
        expect(z, isNotEmpty, reason: '$name empty in zh');
        expect(e, isNotEmpty, reason: '$name empty in en');
      });
    }
  });

  group('en is not a copy of zh', () {
    final cjkKeys = <(String, String, String)>[
      ('tabSessions', zh.tabSessions, en.tabSessions),
      ('settingsTitle', zh.settingsTitle, en.settingsTitle),
      ('loadFailed', zh.loadFailed, en.loadFailed),
      ('retry', zh.retry, en.retry),
      ('cancel', zh.cancel, en.cancel),
      ('convDefaultTitle', zh.convDefaultTitle, en.convDefaultTitle),
      ('permissionRequest', zh.permissionRequest, en.permissionRequest),
      ('notifPermissionTitle', zh.notifPermissionTitle, en.notifPermissionTitle),
    ];

    for (final (name, z, e) in cjkKeys) {
      test('$name en differs from zh and carries no CJK', () {
        expect(_hasCjk(z), isTrue, reason: '$name zh unexpectedly has no CJK');
        expect(e, isNot(z));
        expect(_hasCjk(e), isFalse, reason: '$name en still contains CJK: "$e"');
      });
    }
  });
}
