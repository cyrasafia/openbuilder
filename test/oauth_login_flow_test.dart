import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import 'package:open_builder/app_router.dart';
import 'package:open_builder/app_state.dart';
import 'package:open_builder/core/connection/auth_code_client.dart';
import 'package:open_builder/core/connection/auth_probe.dart';
import 'package:open_builder/core/connection/connection_profile.dart';
import 'package:open_builder/core/connection/loopback_callback_server.dart';
import 'package:open_builder/core/connection/oauth_login_controller.dart';
import 'package:open_builder/features/servers/oauth_login_screen.dart';
import 'package:open_builder/features/servers/server_info_screen.dart';
import 'package:open_builder/l10n/gen/app_localizations.dart';

class _FakePlatformWebViewController extends PlatformWebViewController {
  _FakePlatformWebViewController(super.params) : super.implementation();

  final List<String> loadedUrls = [];

  @override
  Future<void> loadRequest(LoadRequestParams params) async {
    loadedUrls.add(params.uri.toString());
  }

  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async {}

  @override
  Future<void> setPlatformNavigationDelegate(
    covariant PlatformNavigationDelegate delegate,
  ) async {}
}

class _FakePlatformNavigationDelegate extends PlatformNavigationDelegate {
  _FakePlatformNavigationDelegate(super.params) : super.implementation();

  @override
  Future<void> setOnNavigationRequest(
    NavigationRequestCallback callback,
  ) async {}

  @override
  Future<void> setOnPageStarted(PageEventCallback callback) async {}

  @override
  Future<void> setOnPageFinished(PageEventCallback callback) async {}

  @override
  Future<void> setOnProgress(ProgressCallback callback) async {}

  @override
  Future<void> setOnWebResourceError(WebResourceErrorCallback callback) async {}

  @override
  Future<void> setOnUrlChange(UrlChangeCallback callback) async {}

  @override
  Future<void> setOnHttpAuthRequest(HttpAuthRequestCallback callback) async {}

  @override
  Future<void> setOnHttpError(HttpResponseErrorCallback callback) async {}

  @override
  Future<void> setOnSSlAuthError(SslAuthErrorCallback callback) async {}
}

class _FakePlatformWebViewWidget extends PlatformWebViewWidget {
  _FakePlatformWebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

class _FakeWebViewPlatform extends WebViewPlatform {
  final _FakePlatformWebViewController controller =
      _FakePlatformWebViewController(
        const PlatformWebViewControllerCreationParams(),
      );

  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) => controller;

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) => _FakePlatformNavigationDelegate(params);

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) => _FakePlatformWebViewWidget(params);
}

class _FakeAuthCodeClient extends AuthCodeClient {
  int exchangeHits = 0;
  Completer<void>? exchangeGate;

  _FakeAuthCodeClient() : super();

  @override
  Future<LoginSession> startLogin({
    required OidcMetadata meta,
    required String clientId,
    required String audience,
    required String redirectUri,
  }) async {
    return LoginSession(
      authorizationUrl: '${meta.authorizationEndpoint}?fake=1',
      codeVerifier: 'v',
      state: 'st-1',
    );
  }

  @override
  Future<TokenResult> exchangeCode({
    required String tokenEndpoint,
    required String clientId,
    required String redirectUri,
    required String code,
    required String verifier,
  }) async {
    exchangeHits++;
    final gate = exchangeGate;
    if (gate != null && !gate.isCompleted) await gate.future;
    return TokenResult(
      accessToken: 'at-1',
      refreshToken: 'rt-1',
      expiresAtMs: 1,
    );
  }
}

const _meta = OidcMetadata(
  issuer: 'https://auth.example.com',
  authorizationEndpoint: 'https://auth.example.com/authorize',
  tokenEndpoint: 'https://auth.example.com/token',
  parEndpoint: 'https://auth.example.com/par',
);

ConnectionProfile _profile(String id) => ConnectionProfile(
      id: id,
      name: 'S-$id',
      address: 'https://oc.example.com',
      authMethod: AuthMethod.oauth,
      oidcIssuer: _meta.issuer,
      clientId: 'openbuilder-app',
    );

// Regression: a store notification (token persist) used to remount the
// imperatively-pushed login page (go_router refresh re-keys imperative
// matches), aborting the success navigation — on device the fresh screen
// restarted the whole OAuth flow (authz page reappeared).
Future<void> _runFlow(WidgetTester tester, {required bool firstServer}) async {
  final fakePlatform = _FakeWebViewPlatform();
  WebViewPlatform.instance = fakePlatform;
  final client = _FakeAuthCodeClient();

  // Bind the loopback in the real zone; the controller then runs entirely in
  // the fake zone via the providedLoopback seam (no real IO in its chain).
  final loopback = LoopbackCallbackServer();
  await tester.runAsync(() => loopback.start(port: 8901));
  final controller = OAuthLoginController(client: client, providedLoopback: loopback);

  final router = buildRouter(connectionStore);
  await tester.pumpWidget(
    MaterialApp.router(
      routerConfig: router,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
    ),
  );
  await tester.pump();
  // Mirror the add flow: first server came from welcome (go), subsequent
  // adds from server management (pushed above the shell's settings tab).
  if (firstServer) {
    router.go('/servers/new');
    await tester.pumpAndSettle();
  } else {
    router.push('/servers');
    await tester.pumpAndSettle();
    router.push('/servers/new');
    await tester.pumpAndSettle();
  }
  await tester.pumpAndSettle();
  router.push(
    '/servers/p1/login',
    extra: ServerLoginArgs(
      profile: connectionStore.byId('p1')!,
      metadata: _meta,
      newlyAdded: true,
      controller: controller,
    ),
  );
  for (var i = 0;
      i < 20 && controller.phase != OAuthLoginPhase.waitingAuth;
      i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(controller.phase, OAuthLoginPhase.waitingAuth);
  await tester.pump();
  expect(fakePlatform.controller.loadedUrls, isNotEmpty,
      reason: 'WebView never loaded the authz url');

  // Deliver the OAuth callback over a raw socket (flutter_test stubs
  // HttpClient with 400s; plain sockets are untouched).
  await tester.runAsync(() async {
    final socket = await Socket.connect('127.0.0.1', 8901);
    socket.write('GET /callback?code=c-1&state=st-1 HTTP/1.1\r\n'
        'Host: 127.0.0.1:8901\r\nConnection: close\r\n\r\n');
    await socket.flush();
    await socket.first.timeout(const Duration(seconds: 3));
    socket.destroy();
  });
  await tester.pump();
  for (var i = 0;
      i < 20 && controller.phase != OAuthLoginPhase.success;
      i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(controller.phase, OAuthLoginPhase.success,
      reason: 'code exchange never completed');
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 300));

  expect(fakePlatform.controller.loadedUrls.length, 1,
      reason: 'authz url reloaded: ${fakePlatform.controller.loadedUrls}');
  final loc = router.routerDelegate.currentConfiguration.uri.path;
  expect(find.byType(OAuthLoginScreen), findsNothing,
      reason: 'login screen still visible; location=$loc');
  expect(loc, firstServer ? '/sessions' : '/servers');
  expect(connectionStore.byId('p1')!.accessToken, 'at-1');
  expect(connectionStore.activeId, 'p1');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    for (final s in connectionStore.servers.toList()) {
      await connectionStore.remove(s.id);
    }
  });

  testWidgets('first-server oauth success enters /sessions, no authz reload',
      (tester) async {
    await connectionStore.add(_profile('p1'));
    await _runFlow(tester, firstServer: true);
  });

  testWidgets(
      'non-first oauth success returns to /servers with the server active',
      (tester) async {
    await connectionStore.add(_profile('p0'));
    await connectionStore.add(_profile('p1'));
    await _runFlow(tester, firstServer: false);
  });
}
