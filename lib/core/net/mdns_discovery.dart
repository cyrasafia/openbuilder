import 'dart:async';

import 'package:bonsoir/bonsoir.dart';

/// A discovered opencode server on the local network (via mDNS).
class DiscoveredServer {
  final String name;
  final String host; // IP address or `.local` hostname
  final int port;
  const DiscoveredServer({
    required this.name,
    required this.host,
    required this.port,
  });

  String get address => 'http://$host:$port';

  @override
  bool operator ==(Object other) =>
      other is DiscoveredServer && other.host == host && other.port == port;

  @override
  int get hashCode => Object.hash(host, port);

  @override
  String toString() => 'DiscoveredServer($name, $address)';
}

/// Discovers opencode servers on the local network via mDNS (Bonsoir).
///
/// opencode advertises itself as service type `_http._tcp` with the instance
/// name `opencode-<port>` and host `opencode.local` (see
/// packages/opencode/src/server/mdns.ts). We browse `_http._tcp`, resolve each
/// found service to learn its host/port, and keep only `opencode*` instances.
class MdnsDiscovery {
  static const String _type = '_http._tcp';

  final List<DiscoveredServer> _servers = [];
  BonsoirDiscovery? _discovery;
  StreamController<List<DiscoveredServer>>? _ctrl;

  Stream<List<DiscoveredServer>> get stream => _ctrl!.stream;

  Future<void> start() async {
    _ctrl = StreamController<List<DiscoveredServer>>.broadcast();
    final d = BonsoirDiscovery(type: _type);
    _discovery = d;
    await d.initialize();
    d.eventStream?.listen(_onEvent);
    await d.start();
  }

  void _onEvent(BonsoirDiscoveryEvent event) {
    final resolver = _discovery?.serviceResolver;
    if (event is BonsoirDiscoveryServiceFoundEvent) {
      // Trigger resolution so we learn the actual host/port.
      if (resolver != null) {
        event.service.resolve(resolver).catchError((_) {});
      }
    } else if (event is BonsoirDiscoveryServiceResolvedEvent) {
      final svc = event.service;
      if (!svc.name.startsWith('opencode')) return;
      final host = svc.hostAddress ?? svc.hostname;
      if (host == null || host.isEmpty) return;
      final s = DiscoveredServer(name: svc.name, host: host, port: svc.port);
      if (!_servers.contains(s)) {
        _servers.add(s);
        _ctrl?.add(List.unmodifiable(_servers));
      }
    }
  }

  Future<void> stop() async {
    await _discovery?.stop();
    await _ctrl?.close();
    _discovery = null;
    _ctrl = null;
  }
}
