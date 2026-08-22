import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app_router.dart';
import '../../app_state.dart';
import '../../core/connection/auth_probe.dart';
import '../../core/connection/connection_profile.dart';
import '../../core/connection/oauth_login_controller.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../ui/l10n_ext.dart';
import '../../ui/theme.dart';
import '../../core/net/mdns_discovery.dart';

/// Arguments for the login screens pushed after the info step.
class ServerLoginArgs {
  final ConnectionProfile profile;
  final OidcMetadata? metadata;
  final bool newlyAdded;
  final OAuthLoginController? controller;

  const ServerLoginArgs({
    required this.profile,
    required this.metadata,
    required this.newlyAdded,
    this.controller,
  });
}

/// Step 1 of server setup: name + address, then probe the auth method and
/// route to the matching login screen (see design-oauth-login.md).
class ServerInfoScreen extends StatefulWidget {
  final String? id;
  const ServerInfoScreen({super.key, this.id});

  @override
  State<ServerInfoScreen> createState() => _ServerInfoScreenState();
}

enum _ProbeState { idle, running, done }

class _ServerInfoScreenState extends State<ServerInfoScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _address;
  late final TextEditingController _clientId;
  late final TextEditingController _issuer;

  _ProbeState _probeState = _ProbeState.idle;
  AuthProbeResult? _probe;
  String? _probeError;
  bool _saving = false;
  AuthMethod? _manualMethod;
  String? _savedId;
  int _probeGeneration = 0;

  bool get _isEdit => widget.id != null;

  ConnectionProfile? get _existing {
    final id = widget.id ?? _savedId;
    return id == null ? null : connectionStore.byId(id);
  }

  @override
  void initState() {
    super.initState();
    final p = widget.id == null ? null : connectionStore.byId(widget.id!);
    _name = TextEditingController(text: p?.name ?? '');
    _address = TextEditingController(
      text: p?.address ?? 'http://localhost:15120',
    );
    _clientId = TextEditingController(
      text: p == null || p.clientId == ''
          ? ConnectionProfile.defaultClientId
          : p.clientId,
    );
    _issuer = TextEditingController(text: p?.oidcIssuer ?? '');
    // Probe metadata belongs to the address it was fetched from — any manual
    // edit (or mDNS overwrite) must invalidate it, else "Continue" would
    // consume issuer/audience of the previously probed address.
    _address.addListener(_invalidateProbe);
  }

  void _invalidateProbe() {
    _probeGeneration++;
    if (_probeState != _ProbeState.idle || _probe != null || _probeError != null) {
      setState(() {
        _probeState = _ProbeState.idle;
        _probe = null;
        _probeError = null;
      });
    }
  }

  @override
  void dispose() {
    _address.removeListener(_invalidateProbe);
    _name.dispose();
    _address.dispose();
    _clientId.dispose();
    _issuer.dispose();
    super.dispose();
  }

  Future<void> _runProbe() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _probeState = _ProbeState.running;
      _probeError = null;
      _probe = null;
    });
    final generation = _probeGeneration;
    final result = await AuthProbe().probe(_draft().baseUrl);
    if (!mounted) return;
    // The address may have been edited (or a newer probe started) while this
    // one was in flight — a stale result must not route anywhere.
    if (generation != _probeGeneration) return;
    setState(() {
      _probeState = _ProbeState.done;
      _probe = result;
      if (result.outcome == AuthProbeOutcome.oauth && result.oidc != null) {
        _issuer.text = result.oidc!.issuer;
      }
    });
    switch (result.outcome) {
      case AuthProbeOutcome.oauth:
        await _proceed(AuthMethod.oauth);
      case AuthProbeOutcome.basic:
        await _proceed(AuthMethod.basic);
      case AuthProbeOutcome.none:
        await _proceed(AuthMethod.none);
      case AuthProbeOutcome.unknown:
      case AuthProbeOutcome.unreachable:
        break;
    }
  }

  ConnectionProfile _draft({AuthMethod? method}) {
    final old = _existing;
    final sameTarget = old != null &&
        old.address.trim() == _address.text.trim() &&
        old.authMethod == method;
    return ConnectionProfile(
      id: old?.id ?? DateTime.now().microsecondsSinceEpoch.toString(),
      name: _name.text.trim(),
      address: _address.text.trim(),
      username: sameTarget ? old.username : 'opencode',
      password: sameTarget ? old.password : '',
      authMethod: method ?? AuthMethod.none,
      oidcIssuer: _issuer.text.trim(),
      clientId: _clientId.text.trim().isEmpty
          ? ConnectionProfile.defaultClientId
          : _clientId.text.trim(),
      accessToken: sameTarget ? old.accessToken : '',
      refreshToken: sameTarget ? old.refreshToken : '',
      tokenExpiresAt: sameTarget ? old.tokenExpiresAt : null,
      tokenEndpoint: sameTarget ? old.tokenEndpoint : '',
    );
  }

  Future<void> _proceed(AuthMethod method) async {
    final probe = _probe;
    if (method == AuthMethod.oauth &&
        probe?.oidc == null &&
        _issuer.text.trim().isEmpty) {
      setState(() => _probeError = 'issuer');
      return;
    }
    setState(() => _saving = true);
    try {
      final profile = _draft(method: method);
      if (method == AuthMethod.oauth) {
        final meta = probe?.oidc ??
            await AuthProbe().metadataForIssuer(_issuer.text.trim());
        if (meta == null) {
          setState(() => _probeError = 'issuer');
          return;
        }
        final preSave = _existing;
        // Persist the issuer the login actually uses (probed metadata wins
        // over a stale/edited field) so later re-logins can re-fetch config.
        final withMeta = profile.copyWith(
          tokenEndpoint: meta.tokenEndpoint,
          oidcIssuer: meta.issuer,
        );
        // Edit always re-runs the OAuth flow (like add); when the auth
        // target changed, actually drop the stale credentials the snackbar
        // below claims cleared (issuer-only changes bypass _draft's
        // sameTarget reset).
        final configChanged = preSave != null &&
            preSave.accessToken.isNotEmpty &&
            (preSave.authMethod != AuthMethod.oauth ||
                preSave.address.trim() != withMeta.address.trim() ||
                preSave.oidcIssuer != withMeta.oidcIssuer);
        final toSave = configChanged
            ? withMeta.copyWith(
                accessToken: '',
                refreshToken: '',
                tokenExpiresAt: null,
              )
            : withMeta;
        await _saveProfile(toSave);
        if (!mounted) return;
        if (configChanged) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l(context).authMethodChanged)),
          );
        }
        context.push('/servers/${toSave.id}/login', extra: ServerLoginArgs(
          profile: connectionStore.byId(toSave.id) ?? toSave,
          metadata: meta,
          newlyAdded: widget.id == null,
        ));
        return;
      }
      if (method == AuthMethod.none) {
        await _saveProfile(profile);
        if (!mounted) return;
        if (widget.id == null) {
          final router = GoRouter.of(context);
          final firstServer = connectionStore.servers.length == 1;
          await connectionStore.setActive(profile.id);
          if (!mounted) return;
          if (firstServer) {
            router.go('/sessions');
          } else {
            popToServerManagement(router);
          }
        } else {
          context.pop();
        }
        return;
      }
      await _saveProfile(profile);
      if (!mounted) return;
      context.push('/servers/${profile.id}/login',
          extra: ServerLoginArgs(
            profile: connectionStore.byId(profile.id) ?? profile,
            metadata: null,
            newlyAdded: widget.id == null,
          ));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveProfile(ConnectionProfile p) async {
    // Branch on the live store entry, not _savedId: if the entry vanished,
    // update() would silently no-op and nothing would be persisted.
    if (_existing != null) {
      await connectionStore.update(p);
    } else {
      await connectionStore.add(p);
      _savedId = p.id;
    }
  }

  Future<void> _chooseManual() async {
    final loc = l(context);
    final method = await showDialog<AuthMethod>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(loc.probeUnknown),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, AuthMethod.basic),
            child: Text(loc.probeMethodBasic),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, AuthMethod.none),
            child: Text(loc.probeMethodNone),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, AuthMethod.oauth),
            child: Text(loc.probeMethodOauth),
          ),
        ],
      ),
    );
    if (method == null) return;
    setState(() {
      _manualMethod = method;
      _probe = AuthProbeResult(outcome: method == AuthMethod.oauth
          ? AuthProbeOutcome.unknown
          : method == AuthMethod.basic
              ? AuthProbeOutcome.basic
              : AuthProbeOutcome.none);
    });
    if (method == AuthMethod.oauth) {
      // OAuth needs the issuer filled in first — stay on the form (the
      // continue button below the fields re-invokes _proceed).
      return;
    }
    await _proceed(method);
  }

  Future<void> _delete() async {
    final loc = l(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(loc.serverFormDelete),
        content: Text(loc.serverFormDeleteConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(loc.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(loc.delete),
          ),
        ],
      ),
    );
    if (confirmed != true || widget.id == null) return;
    await connectionStore.remove(widget.id!);
    if (!mounted) return;
    context.go(connectionStore.isEmpty ? '/welcome' : '/settings');
  }

  @override
  Widget build(BuildContext context) {
    final loc = l(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEdit ? loc.serverFormEditTitle : loc.serverFormAddTitle),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _field(
                label: loc.serverFormFieldName,
                controller: _name,
                icon: Icons.label_outline,
                validator: (v) => (v == null || v.trim().isEmpty)
                    ? loc.serverFormRequired
                    : null,
              ),
              const SizedBox(height: 12),
              _field(
                label: loc.serverFormFieldAddress,
                controller: _address,
                icon: Icons.link,
                hint: loc.serverFormAddressHint,
                validator: (v) => (v == null || v.trim().isEmpty)
                    ? loc.serverFormRequired
                    : null,
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _discover,
                  icon: const Icon(Icons.wifi_find),
                  label: Text(loc.serverFormDiscoverMdns),
                ),
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed:
                    _probeState == _ProbeState.running || _saving
                        ? null
                        : _runProbe,
                icon: _probeState == _ProbeState.running
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.travel_explore),
                label: Text(loc.probeNext),
              ),
              if (_probeState == _ProbeState.running) ...[
                const SizedBox(height: 12),
                Text(
                  loc.probeRunning,
                  style: const TextStyle(fontSize: 13),
                ),
              ],
              if (_probeState == _ProbeState.done) ..._probeResults(loc),
              if (_isEdit) ...[
                const SizedBox(height: 16),
                FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(
                    foregroundColor: Colors.red,
                    backgroundColor: Colors.red.withAlpha(25),
                  ),
                  onPressed: _delete,
                  icon: const Icon(Icons.delete_outline),
                  label: Text(loc.serverFormDelete),
                ),
              ],
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _probeResults(AppLocalizations loc) {
    switch (_probe!.outcome) {
      case AuthProbeOutcome.unreachable:
        return [
          const SizedBox(height: 12),
          Text(
            loc.probeUnreachable,
            style: const TextStyle(color: Colors.red, fontSize: 13),
          ),
        ];
      case AuthProbeOutcome.unknown:
        return [
          const SizedBox(height: 12),
          Text(loc.probeUnknown, style: const TextStyle(fontSize: 13)),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _chooseManual,
            icon: const Icon(Icons.tune),
            label: Text(loc.probeChooseManually),
          ),
          ..._manualOauthFields(loc),
          if (_manualMethod == AuthMethod.oauth) ...[
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _saving ? null : () => _proceed(AuthMethod.oauth),
              icon: const Icon(Icons.login),
              label: Text(loc.probeContinue),
            ),
          ],
        ];
      // oauth / basic / none route away immediately after the probe.
      case AuthProbeOutcome.oauth:
      case AuthProbeOutcome.basic:
      case AuthProbeOutcome.none:
        return const [];
    }
  }

  List<Widget> _manualOauthFields(AppLocalizations loc) {
    return [
      const SizedBox(height: 12),
      _field(
        label: loc.fieldClientId,
        controller: _clientId,
        icon: Icons.badge_outlined,
      ),
      const SizedBox(height: 12),
      _field(
        label: loc.fieldIssuer,
        controller: _issuer,
        icon: Icons.verified_outlined,
        hint: 'https://',
      ),
      if (_probeError == 'issuer')
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            loc.probeIssuerRequired,
            style: const TextStyle(color: Colors.red, fontSize: 12),
          ),
        ),
    ];
  }

  Future<void> _discover() async {
    final server = await showDialog<DiscoveredServer>(
      context: context,
      builder: (_) => const _MdnsDiscoveryDialog(),
    );
    if (server != null && mounted) {
      _address.text = server.address; // listener invalidates the probe
      if (_name.text.trim().isEmpty) _name.text = server.name;
    }
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    String? hint,
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: controller,
      validator: validator,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: Icon(icon),
        border: const OutlineInputBorder(),
      ),
    );
  }
}

class _MdnsDiscoveryDialog extends StatefulWidget {
  const _MdnsDiscoveryDialog();

  @override
  State<_MdnsDiscoveryDialog> createState() => _MdnsDiscoveryDialogState();
}

class _MdnsDiscoveryDialogState extends State<_MdnsDiscoveryDialog> {
  final _mdns = MdnsDiscovery();
  List<DiscoveredServer> _servers = [];
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      await _mdns.start();
      _mdns.stream.listen((list) {
        if (mounted) setState(() => _servers = list);
      });
    } catch (_) {
      if (mounted) setState(() => _error = true);
    }
  }

  @override
  void dispose() {
    _mdns.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final loc = l(context);
    return AlertDialog(
      title: Text(loc.mdnsDialogTitle),
      content: SizedBox(
        width: double.maxFinite,
        height: 320,
        child: _servers.isEmpty
            ? Center(
                child: _error
                    ? Text(loc.mdnsUnavailable, textAlign: TextAlign.center)
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CircularProgressIndicator(),
                          const SizedBox(height: 12),
                          Text(
                            loc.mdnsScanning,
                            style: const TextStyle(fontSize: 13),
                          ),
                        ],
                      ),
              )
            : ListView.separated(
                itemCount: _servers.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final s = _servers[i];
                  return ListTile(
                    leading: const Icon(Icons.dns_outlined),
                    title: Text(s.name),
                    subtitle: Text(
                      s.address,
                      style: AppTheme.mono.copyWith(fontSize: 12),
                    ),
                    onTap: () => Navigator.pop(context, s),
                  );
                },
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(loc.cancel),
        ),
      ],
    );
  }
}
