import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app_state.dart';
import '../../core/connection/connection_profile.dart';
import '../../core/net/dio_factory.dart';
import '../../ui/l10n_ext.dart';
import '../../ui/theme.dart';
import '../../core/net/mdns_discovery.dart';
import '../../data/api/opencode_client.dart';

/// Add (id == null) or edit (id != null) a server. Includes test connection.
class ServerFormScreen extends StatefulWidget {
  final String? id;
  const ServerFormScreen({super.key, this.id});

  @override
  State<ServerFormScreen> createState() => _ServerFormScreenState();
}

class _ServerFormScreenState extends State<ServerFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _address;
  late final TextEditingController _username;
  late final TextEditingController _password;

  bool _testing = false;
  bool _saving = false;
  String? _testMsg;
  String? _testVersion;

  bool get _isEdit => widget.id != null;

  @override
  void initState() {
    super.initState();
    final p = widget.id == null ? null : connectionStore.byId(widget.id!);
    _name = TextEditingController(text: p?.name ?? '');
    _address = TextEditingController(
      text: p?.address ?? 'http://localhost:15120',
    );
    _username = TextEditingController(text: p?.username ?? 'opencode');
    _password = TextEditingController(text: p?.password ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  ConnectionProfile _profileFromFields({String? id}) => ConnectionProfile(
    id: id ?? DateTime.now().microsecondsSinceEpoch.toString(),
    name: _name.text.trim(),
    address: _address.text.trim(),
    username: _username.text.trim().isEmpty
        ? 'opencode'
        : _username.text.trim(),
    password: _password.text,
  );

  Future<void> _test() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _testing = true;
      _testMsg = null;
      _testVersion = null;
    });
    try {
      final client = OpencodeClient(dioFor(_profileFromFields()));
      final h = await client.health();
      setState(() {
        _testVersion = h.version;
        _testMsg = null;
      });
    } on DioException catch (e) {
      setState(() {
        _testMsg =
            '✗ ${e.response?.statusCode ?? e.type.name} ${e.message ?? ''}';
      });
    } catch (e) {
      setState(() {
        _testMsg = '✗ $e';
      });
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    // Known platform limit: on web, EventSource can't send auth headers, so a
    // non-empty basic-auth password makes the SSE stream 401 and live updates
    // break (mobile uses the IO transport + dio header, unaffected). The app
    // targets mobile; this is just a fallback heads-up when used on web.
    if (kIsWeb && _password.text.isNotEmpty) {
      final proceed = await _warnWebBasicAuth();
      if (!proceed) return;
    }
    setState(() => _saving = true);
    try {
      final p = _profileFromFields(id: widget.id);
      if (_isEdit) {
        await connectionStore.update(p);
      } else {
        await connectionStore.add(p);
        await connectionStore.setActive(p.id);
      }
      if (!mounted) return;
      context.go('/sessions');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<bool> _warnWebBasicAuth() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, color: Colors.orange),
            const SizedBox(width: 8),
            Text(l(ctx).webBasicAuthTitle),
          ],
        ),
        content: Text(l(ctx).webBasicAuthBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l(ctx).cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l(ctx).webBasicAuthProceed),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l(ctx).serverFormDelete),
        content: Text(l(ctx).serverFormDeleteConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l(ctx).cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l(ctx).delete),
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
              const SizedBox(height: 12),
              _field(
                label: loc.serverFormFieldUsername,
                controller: _username,
                icon: Icons.person_outline,
                hint: loc.serverFormUsernameHint,
              ),
              const SizedBox(height: 12),
              _field(
                label: loc.serverFormFieldPassword,
                controller: _password,
                icon: Icons.lock_outline,
                obscure: true,
                hint: loc.serverFormPasswordHint,
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: _testing ? null : _test,
                      icon: _testing
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.cable),
                      label: Text(loc.serverFormTestConnection),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _saving ? null : _save,
                      icon: const Icon(Icons.save),
                      label: Text(loc.save),
                    ),
                  ),
                ],
              ),
              if (_testVersion != null) ...[
                const SizedBox(height: 12),
                Text(
                  loc.serverFormTestSuccess(_testVersion!),
                  style: const TextStyle(color: Colors.green, fontSize: 13),
                ),
              ] else if (_testMsg != null) ...[
                const SizedBox(height: 12),
                Text(
                  _testMsg!,
                  style: const TextStyle(color: Colors.red, fontSize: 13),
                ),
              ],
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _discover,
                  icon: const Icon(Icons.wifi_find),
                  label: Text(loc.serverFormDiscoverMdns),
                ),
              ),
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

  Future<void> _discover() async {
    final server = await showDialog<DiscoveredServer>(
      context: context,
      builder: (_) => const _MdnsDiscoveryDialog(),
    );
    if (server != null && mounted) {
      _address.text = server.address;
      if (_name.text.trim().isEmpty) _name.text = server.name;
      if (_username.text.trim().isEmpty) _username.text = 'opencode';
    }
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    String? hint,
    bool obscure = false,
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: controller,
      obscureText: obscure,
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
