import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app_router.dart';
import '../../app_state.dart';
import '../../core/connection/connection_profile.dart';
import '../../core/connection/connection_store.dart';
import '../../core/logging/app_logger.dart';
import '../../core/net/dio_factory.dart';
import '../../data/api/opencode_client.dart';
import '../../ui/l10n_ext.dart';

/// Verification dio for the credential step. The query interceptor is
/// PINNED to [draft] — the password under test lives only in the input box,
/// so a live-store read would replay the stale one and fail forever. The
/// gateway token still refreshes through the store (AuthInterceptor touches
/// tokens only, never the password).
Dio credentialVerificationDio(
  ConnectionProfile draft, {
  required ConnectionStore store,
}) {
  final dio = Dio(BaseOptions(
    baseUrl: draft.baseUrl,
    connectTimeout: const Duration(seconds: 8),
    receiveTimeout: const Duration(seconds: 20),
    headers: {'Accept': 'application/json', ...authHeadersFor(draft)},
  ));
  dio.interceptors.add(AuthInterceptor(dio, draft, store: store));
  dio.interceptors.add(AuthTokenQueryInterceptor(draft));
  return dio;
}

/// opencode credential step: password only (the username is fixed to
/// `opencode` — v2 rejects anything else). Two modes share this screen:
///  - basic profile: password alone on the wire (flagged insecure).
///  - oauth profile: the password rides `?auth_token=` behind the gateway
///    Bearer token (step 2 of the two-step oauth login).
/// Tests against the live server, persists on success.
class BasicAuthScreen extends StatefulWidget {
  final ConnectionProfile profile;
  final bool newlyAdded;

  const BasicAuthScreen({
    super.key,
    required this.profile,
    required this.newlyAdded,
  });

  @override
  State<BasicAuthScreen> createState() => _BasicAuthScreenState();
}

class _BasicAuthScreenState extends State<BasicAuthScreen> {
  static const _tag = 'BasicAuth';
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _password;

  bool _testing = false;
  String? _error;

  bool get _behindGateway => widget.profile.authMethod == AuthMethod.oauth;

  @override
  void initState() {
    super.initState();
    _password = TextEditingController(text: widget.profile.password);
  }

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _testAndSave() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final loc = l(context);
    final router = GoRouter.of(context);
    // Known platform limit (ported from the old form screen): web's
    // EventSource can't send the Authorization header — basic auth loses
    // its credential, oauth loses the gateway Bearer — so SSE live updates
    // break there in BOTH modes. Mobile (IO transport) is unaffected.
    if (kIsWeb) {
      final proceed = await _warnWebBasicAuth();
      if (!proceed) return;
    }
    setState(() {
      _testing = true;
      _error = null;
    });
    final draft = widget.profile.copyWith(
      username: 'opencode',
      password: _password.text,
    );
    try {
      // behindGateway: verify the FULL two-layer composition with the
      // password from the input box (see credentialVerificationDio).
      final dio = _behindGateway
          ? credentialVerificationDio(draft, store: connectionStore)
          : dioFor(draft);
      await OpencodeClient(dio).health();
    } on DioException catch (e) {
      if (!mounted) return;
      setState(() {
        _testing = false;
        // A gateway-layer rejection (refresh refused during verification)
        // must not masquerade as a wrong password.
        _error = e.response?.statusCode == 401
            ? (connectionStore.authBrokenScope(draft.id) ==
                    AuthBrokenScope.gateway
                ? loc.serverAuthBroken
                : loc.basicWrongCredentials)
            : '✗ ${e.response?.statusCode ?? e.type.name} ${e.message ?? ''}';
      });
      return;
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _testing = false;
        _error = '✗ $e';
      });
      return;
    }
    final firstServer =
        widget.newlyAdded && connectionStore.servers.length == 1;
    AppLogger.I.i(_tag, 'test&save ok: id=${draft.id} '
        'newlyAdded=${widget.newlyAdded} firstServer=$firstServer '
        'behindGateway=$_behindGateway');
    try {
      await connectionStore.update(draft);
      AppLogger.I.i(_tag, 'profile persisted');
      if (mounted) setState(() => _testing = false);
      await connectionStore.setActive(draft.id);
      AppLogger.I.i(_tag, 'set active done, navigating');
    } catch (e, s) {
      // Secure-storage / persist failures used to abort silently here — the
      // screen stayed on the password page with no feedback. Surface it.
      AppLogger.I.e(_tag, 'persist failed: $e\n$s');
      if (mounted) {
        setState(() {
          _testing = false;
          _error = '✗ $e';
        });
      }
      return;
    }
    if (firstServer) {
      router.go('/sessions');
    } else {
      popToServerManagement(router);
    }
    AppLogger.I.i(_tag, 'navigation done');
  }

  Future<bool> _warnWebBasicAuth() async {
    final loc = l(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, color: Colors.orange),
            const SizedBox(width: 8),
            Flexible(child: Text(loc.webBasicAuthTitle)),
          ],
        ),
        content: Text(loc.webBasicAuthBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(loc.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(loc.webBasicAuthProceed),
          ),
        ],
      ),
    );
    return ok == true;
  }

  @override
  Widget build(BuildContext context) {
    final loc = l(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _behindGateway ? loc.gatewayCredentialTitle : loc.basicTitle,
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_behindGateway) ...[
                Text(loc.gatewayCredentialHint,
                    style: const TextStyle(fontSize: 13)),
                const SizedBox(height: 12),
              ] else ...[
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.orange.withAlpha(20),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.orange.withAlpha(70)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.gpp_maybe_outlined,
                          size: 18, color: Colors.orange.shade700),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          loc.basicInsecureNote,
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurface.withAlpha(180),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
              ],
              TextFormField(
                controller: _password,
                obscureText: true,
                validator: (v) =>
                    (v == null || v.isEmpty) ? loc.serverFormRequired : null,
                decoration: InputDecoration(
                  labelText: loc.serverFormFieldPassword,
                  hintText: loc.serverFormPasswordHint,
                  prefixIcon: const Icon(Icons.lock_outline),
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _testing ? null : _testAndSave,
                icon: _testing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save),
                label: Text(loc.basicTestSave),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: const TextStyle(color: Colors.red, fontSize: 13),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
