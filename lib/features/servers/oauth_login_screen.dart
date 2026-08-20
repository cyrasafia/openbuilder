import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../app_state.dart';
import '../../core/connection/auth_probe.dart';
import '../../core/connection/connection_profile.dart';
import '../../core/connection/oauth_login_controller.dart';
import '../../ui/l10n_ext.dart';

/// In-app WebView login: keeps the app foregrounded so the loopback receiver
/// never misses the single-shot redirect (the v2 system-browser dead-end —
/// see design-oauth-login.md ADR). The AppBar permanently shows the auth
/// host as the anti-phishing anchor.
///
/// [metadata] may be null for re-login (only the issuer is persisted) — it is
/// re-fetched from `/.well-known` before the flow starts.
class OAuthLoginScreen extends StatefulWidget {
  final ConnectionProfile profile;
  final OidcMetadata? metadata;
  final bool newlyAdded;

  const OAuthLoginScreen({
    super.key,
    required this.profile,
    required this.metadata,
    required this.newlyAdded,
  });

  @override
  State<OAuthLoginScreen> createState() => _OAuthLoginScreenState();
}

class _OAuthLoginScreenState extends State<OAuthLoginScreen> {
  late final OAuthLoginController _controller;
  WebViewController? _web;
  OidcMetadata? _meta;
  bool _metaFetchFailed = false;
  bool _dialogShown = false;

  @override
  void initState() {
    super.initState();
    _controller = OAuthLoginController()..addListener(_onPhase);
    final meta = widget.metadata;
    if (meta != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _start(meta);
      });
    } else {
      AuthProbe()
          .metadataForIssuer(widget.profile.oidcIssuer)
          .then((fetched) {
        if (!mounted) return;
        if (fetched == null) {
          setState(() => _metaFetchFailed = true);
          return;
        }
        _start(fetched);
      });
    }
  }

  void _start(OidcMetadata meta) {
    setState(() => _meta = meta);
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(onNavigationRequest: _onNavigation),
      );
    _controller.start(
      profile: widget.profile,
      meta: meta,
      callbackMessage: l(context).oauthCallbackReceived,
    );
  }

  NavigationDecision _onNavigation(NavigationRequest request) {
    final meta = _meta;
    if (meta == null) return NavigationDecision.prevent;
    final uri = Uri.tryParse(request.url);
    if (uri != null && (uri.isScheme('http') || uri.isScheme('https'))) {
      try {
        if (_allowedOrigins(meta).contains(uri.origin)) {
          return NavigationDecision.navigate;
        }
      } on Object {
        // malformed origin — fall through to prevent
      }
    }
    return NavigationDecision.prevent;
  }

  Set<String> _allowedOrigins(OidcMetadata meta) {
    return <String>{
      Uri.parse(meta.issuer).origin,
      Uri.parse(meta.authorizationEndpoint).origin,
      _controller.loopbackOrigin,
    };
  }

  void _onPhase() {
    final phase = _controller.phase;
    if (phase == OAuthLoginPhase.waitingAuth &&
        !_dialogShown &&
        _web != null &&
        _controller.authorizationUrl != null) {
      _web!.loadRequest(Uri.parse(_controller.authorizationUrl!));
    }
    if (phase == OAuthLoginPhase.success) {
      _persistAndLeave();
      return;
    }
    if (_isErrorPhase(phase) && !_dialogShown && mounted) {
      _dialogShown = true;
      _showErrorDialog();
    }
  }

  bool _isErrorPhase(OAuthLoginPhase phase) =>
      phase == OAuthLoginPhase.parError ||
      phase == OAuthLoginPhase.portBusy ||
      phase == OAuthLoginPhase.csrfError ||
      phase == OAuthLoginPhase.denied ||
      phase == OAuthLoginPhase.flowError ||
      phase == OAuthLoginPhase.timeout ||
      phase == OAuthLoginPhase.exchangeError;

  String _errorText() {
    final loc = l(context);
    return switch (_controller.phase) {
      OAuthLoginPhase.parError => loc.oauthErrPar,
      OAuthLoginPhase.portBusy => loc.oauthErrPortBusy,
      OAuthLoginPhase.csrfError => loc.oauthErrCsrf,
      OAuthLoginPhase.denied => loc.oauthErrDenied,
      OAuthLoginPhase.timeout => loc.oauthErrTimeout,
      OAuthLoginPhase.exchangeError => loc.oauthErrExchange,
      _ => loc.oauthErrFlow,
    };
  }

  Future<void> _showErrorDialog() async {
    final loc = l(context);
    final meta = _meta;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(loc.oauthErrTitle),
        content: Text(_errorText()),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _controller.cancel();
              if (mounted) context.pop();
            },
            child: Text(loc.cancel),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              if (meta == null) {
                if (mounted) context.pop();
                return;
              }
              setState(() => _dialogShown = false);
              _controller.restart(
                profile: widget.profile,
                meta: meta,
                callbackMessage: l(context).oauthCallbackReceived,
              );
            },
            child: Text(loc.oauthRetry),
          ),
        ],
      ),
    );
  }

  Future<void> _persistAndLeave() async {
    final tokens = _controller.tokenResult;
    final meta = _meta;
    if (tokens == null || meta == null) return;
    final updated = widget.profile.copyWith(
      accessToken: tokens.accessToken,
      refreshToken: tokens.refreshToken,
      tokenExpiresAt: tokens.expiresAtMs,
      tokenEndpoint: meta.tokenEndpoint,
    );
    await connectionStore.update(updated);
    if (!mounted) return;
    if (widget.newlyAdded) {
      await connectionStore.setActive(updated.id);
      if (mounted) context.go('/sessions');
    } else {
      context.pop();
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onPhase);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final loc = l(context);
    final scheme = Theme.of(context).colorScheme;
    final meta = _meta;
    if (meta == null) {
      return Scaffold(
        appBar: AppBar(title: Text(loc.oauthLoginTitle(widget.profile.name))),
        body: Center(
          child: _metaFetchFailed
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(loc.oauthErrIssuerFetch),
                    const SizedBox(height: 12),
                    OutlinedButton(
                      onPressed: () => context.pop(),
                      child: Text(loc.cancel),
                    ),
                  ],
                )
              : const CircularProgressIndicator(),
        ),
      );
    }
    final host = Uri.tryParse(meta.issuer)?.host ?? meta.issuer;
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _controller.cancel();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(loc.oauthLoginTitle(widget.profile.name),
                  style: const TextStyle(fontSize: 16)),
              Text(
                host,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w300,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          centerTitle: true,
        ),
        body: Column(
          children: [
            Expanded(
              child: _web == null
                  ? const Center(child: CircularProgressIndicator())
                  : WebViewWidget(controller: _web!),
            ),
            SafeArea(
              top: false,
              child: ListenableBuilder(
                listenable: _controller,
                builder: (context, _) => Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: SizedBox(height: 18, child: _statusRow(scheme)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget? _statusRow(ColorScheme scheme) {
    final loc = l(context);
    Widget? text;
    switch (_controller.phase) {
      case OAuthLoginPhase.waitingAuth:
        text = Text(loc.oauthWaitingAuth,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant));
      case OAuthLoginPhase.exchanging:
        text = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 8),
            Text(loc.oauthExchanging,
                style:
                    TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          ],
        );
      case OAuthLoginPhase.success:
        text = Text(loc.oauthSuccess,
            style: TextStyle(fontSize: 12, color: Colors.green));
      default:
        text = null;
    }
    if (text == null) return null;
    return Align(alignment: Alignment.centerLeft, child: text);
  }
}
