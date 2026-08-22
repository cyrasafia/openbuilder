import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import 'package:open_builder/app_router.dart';
import 'package:open_builder/app_state.dart';
import 'package:open_builder/core/connection/connection_profile.dart';
import 'package:open_builder/features/servers/oauth_login_screen.dart';
import 'package:open_builder/features/servers/server_info_screen.dart';
import 'package:open_builder/l10n/gen/app_localizations.dart';

class _FakePlatformWebViewController extends PlatformWebViewController {
  _FakePlatformWebViewController(super.params) : super.implementation();

  @override
  Future<void> loadRequest(LoadRequestParams params) async {}

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
  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) => _FakePlatformWebViewController(params);

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) => _FakePlatformNavigationDelegate(params);

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) => _FakePlatformWebViewWidget(params);
}

String _metaBody(String issuer) => '{"issuer":"$issuer",'
    '"authorization_endpoint":"$issuer/authorize",'
    '"token_endpoint":"$issuer/token",'
    '"pushed_authorization_request_endpoint":"$issuer/par"}';

class _ProbeHttpOverrides extends HttpOverrides {
  _ProbeHttpOverrides(this.issuer);

  final String issuer;

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _FakeHttpClient(issuer);
}

class _FakeHttpClient implements HttpClient {
  _FakeHttpClient(this.issuer);

  final String issuer;

  @override
  Duration? connectionTimeout;

  @override
  Duration idleTimeout = Duration.zero;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _FakeRequest(method, url, issuer);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeRequest implements HttpClientRequest {
  _FakeRequest(this.method, this.url, this.issuer);

  @override
  final String method;

  final Uri url;

  final String issuer;

  @override
  final HttpHeaders headers = _FakeHeaders();

  @override
  bool followRedirects = true;

  @override
  int maxRedirects = 5;

  @override
  bool persistentConnection = true;

  @override
  void add(List<int> data) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.drain<void>();

  @override
  void write(Object? obj) {}

  @override
  Future<HttpClientResponse> close() async => _route(method, url, issuer);

  @override
  Future<HttpClientResponse> get done => close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHeaders implements HttpHeaders {
  final Map<String, List<String>> _map = {};

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) =>
      _map[name.toLowerCase()] = [value.toString()];

  @override
  void forEach(void Function(String name, List<String> values) f) =>
      _map.forEach(f);

  @override
  String? value(String name) => _map[name.toLowerCase()]?.join(',');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeResponse extends Stream<List<int>> implements HttpClientResponse {
  _FakeResponse(this.statusCode, this._body);

  @override
  final int statusCode;

  final List<int> _body;

  @override
  final HttpHeaders headers = _FakeHeaders();

  @override
  bool get isRedirect => false;

  @override
  String get reasonPhrase => '';

  @override
  List<RedirectInfo> get redirects => const [];

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      Stream<List<int>>.fromIterable([_body]).listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

HttpClientResponse _route(String method, Uri url, String issuer) {
  if (method == 'GET') {
    if (url.toString() == 'http://oc.example.com/global/health') {
      return _FakeResponse(
        200,
        utf8.encode('{"healthy":true,"version":"1.2.3"}'),
      );
    }
    if (url.toString() ==
        'http://oc.example.com/.well-known/oauth-authorization-server') {
      return _FakeResponse(200, utf8.encode(_metaBody(issuer)));
    }
  }
  return _FakeResponse(400, const []);
}

ConnectionProfile _profile() => ConnectionProfile(
      id: 'p1',
      name: 'S-1',
      address: 'http://oc.example.com',
      authMethod: AuthMethod.oauth,
      oidcIssuer: 'https://auth.example.com',
      tokenEndpoint: 'https://auth.example.com/token',
      clientId: 'openbuilder-app',
      accessToken: 'old-token',
      refreshToken: 'old-refresh',
      tokenExpiresAt: 12345,
    );

// The pushed screen runs a real controller that binds the default loopback
// port (8901) — reserved for oauth_login_flow_test (see the OL-36 note in
// review-oauth-login.md). Give it enough real event-loop time to reach its
// terminal parError (fake 400) so it tears the receiver down BEFORE the test
// exits instead of holding the port until tree disposal.
Future<void> _releaseLoopback(WidgetTester tester) async {
  await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 400)));
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

// Regression: editing an oauth server and tapping "Next" used to pop straight
// back (unchanged address/issuer + existing token shortcut) instead of
// re-running the OAuth flow like the add path. The probe must always land on
// the login screen.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    for (final s in connectionStore.servers.toList()) {
      await connectionStore.remove(s.id);
    }
    WebViewPlatform.instance = _FakeWebViewPlatform();
  });

  tearDown(() {
    HttpOverrides.global = null;
  });

  testWidgets('editing an oauth server re-runs the login flow', (tester) async {
    HttpOverrides.global = _ProbeHttpOverrides('https://auth.example.com');
    await connectionStore.add(_profile());
    final router = buildRouter(connectionStore);
    await tester.pumpWidget(
      MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    );
    await tester.pump();
    router.go('/servers/p1/edit');
    await tester.pumpAndSettle();
    expect(find.byType(ServerInfoScreen), findsOneWidget);

    await tester.tap(find.byIcon(Icons.travel_explore));
    for (var i = 0;
        i < 40 && find.byType(OAuthLoginScreen).evaluate().isEmpty;
        i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.byType(OAuthLoginScreen), findsOneWidget,
        reason: 'edit must push the oauth login screen, not pop');
    final saved = connectionStore.byId('p1')!;
    expect(saved.authMethod, AuthMethod.oauth);
    expect(saved.accessToken, 'old-token',
        reason: 'existing token stays until the new flow replaces it');
    final loc = AppLocalizations.of(
        tester.element(find.byType(OAuthLoginScreen)))!;
    expect(find.text(loc.authMethodChanged), findsNothing,
        reason: 'unchanged config must not claim credentials were cleared');
    await _releaseLoopback(tester);
  });

  // The probe returning a different issuer (server-side IdP reconfiguration)
  // is the one config change _draft's sameTarget check cannot see — the
  // snackbar's "old credentials cleared" claim must be made true by actually
  // clearing them.
  testWidgets('issuer change clears stale credentials with a warning',
      (tester) async {
    HttpOverrides.global = _ProbeHttpOverrides('https://auth2.example.com');
    await connectionStore.add(_profile());
    final router = buildRouter(connectionStore);
    await tester.pumpWidget(
      MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    );
    await tester.pump();
    router.go('/servers/p1/edit');
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.travel_explore));
    for (var i = 0;
        i < 40 && find.byType(OAuthLoginScreen).evaluate().isEmpty;
        i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.byType(OAuthLoginScreen), findsOneWidget);
    final saved = connectionStore.byId('p1')!;
    expect(saved.oidcIssuer, 'https://auth2.example.com');
    expect(saved.tokenEndpoint, 'https://auth2.example.com/token');
    expect(saved.accessToken, '', reason: 'stale token must be cleared');
    expect(saved.refreshToken, '');
    expect(saved.tokenExpiresAt, isNull);
    final loc = AppLocalizations.of(
        tester.element(find.byType(OAuthLoginScreen)))!;
    // Every mounted Scaffold registered with the root messenger renders the
    // current snackbar — scope to the pushed login screen (the visible one).
    expect(
      find.descendant(
        of: find.byType(OAuthLoginScreen),
        matching: find.text(loc.authMethodChanged),
      ),
      findsOneWidget,
    );
    await _releaseLoopback(tester);
  });
}
