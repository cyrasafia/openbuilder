import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app_router.dart';
import '../../app_state.dart';
import '../../core/connection/connection_profile.dart';
import '../../core/logging/app_logger.dart';
import '../../core/net/dio_factory.dart';
import '../../data/api/opencode_client.dart';
import '../../ui/l10n_ext.dart';

/// Basic credential step: username + password, test against the live server,
/// persist on success. Reached from the info probe (basic) or re-login.
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
  late final TextEditingController _username;
  late final TextEditingController _password;

  bool _testing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _username = TextEditingController(text: widget.profile.username);
    _password = TextEditingController(text: widget.profile.password);
  }

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _testAndSave() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final loc = l(context);
    final router = GoRouter.of(context);
    // Known platform limit (ported from the old form screen): web's
    // EventSource can't send auth headers, so a non-empty basic password
    // breaks SSE live updates there. Mobile (IO transport) is unaffected.
    if (kIsWeb && _password.text.isNotEmpty) {
      final proceed = await _warnWebBasicAuth();
      if (!proceed) return;
    }
    setState(() {
      _testing = true;
      _error = null;
    });
    final draft = widget.profile.copyWith(
      username: _username.text.trim().isEmpty
          ? 'opencode'
          : _username.text.trim(),
      password: _password.text,
      // A server that accepts an empty password has no auth configured
      // (opencode treats an unset OPENCODE_SERVER_PASSWORD as no auth) —
      // persisting `basic` with an empty password would flag the profile
      // "not logged in" forever.
      authMethod:
          _password.text.isEmpty ? AuthMethod.none : AuthMethod.basic,
    );
    try {
      await OpencodeClient(dioFor(draft)).health();
    } on DioException catch (e) {
      if (!mounted) return;
      setState(() {
        _testing = false;
        _error = e.response?.statusCode == 401
            ? loc.basicWrongCredentials
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
        'newlyAdded=${widget.newlyAdded} firstServer=$firstServer');
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
    return Scaffold(
      appBar: AppBar(title: Text(loc.basicTitle)),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: _username,
                decoration: InputDecoration(
                  labelText: loc.serverFormFieldUsername,
                  hintText: loc.serverFormUsernameHint,
                  prefixIcon: const Icon(Icons.person_outline),
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _password,
                obscureText: true,
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
