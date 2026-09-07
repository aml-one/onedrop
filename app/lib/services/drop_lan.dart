import 'dart:io';

/// How long a hello stays live without a fresh UDP packet.
const dropPeerTtl = Duration(seconds: 8);

const _neighborCacheTtl = Duration(seconds: 12);

DateTime? _neighborCacheAt;
List<InternetAddress> _neighborCache = const [];

/// Limited broadcast is ignored on macOS. Also send to each IPv4 /24 .255.
InternetAddress? subnetBroadcast24(InternetAddress addr) {
  if (addr.type != InternetAddressType.IPv4 || addr.isLoopback) return null;
  final b = addr.rawAddress;
  if (b.length != 4) return null;
  return InternetAddress('${b[0]}.${b[1]}.${b[2]}.255');
}

bool dropIsVirtualInterface(String name) {
  final n = name.toLowerCase();
  const needles = [
    'vethernet',
    'wsl',
    'hyper-v',
    'docker',
    'vbox',
    'virtualbox',
    'vmware',
    'loopback',
    'bluetooth',
    'isatap',
    'teredo',
    'tailscale',
    'zerotier',
    'hamachi',
    'npcap',
    'virbr',
    'veth',
    'awdl',
    'llw',
  ];
  return needles.any(n.contains);
}

bool _isUsableLanIpv4(InternetAddress addr) {
  if (addr.type != InternetAddressType.IPv4 || addr.isLoopback) return false;
  final b = addr.rawAddress;
  if (b.length != 4) return false;
  // Link-local / APIPA
  if (b[0] == 169 && b[1] == 254) return false;
  // Carrier-grade NAT (phone mobile data)
  if (b[0] == 100 && b[1] >= 64 && b[1] <= 127) return false;
  return true;
}

List<InternetAddress> dropLocalIpv4(Iterable<NetworkInterface> ifaces) {
  return [
    for (final iface in ifaces)
      if (!dropIsVirtualInterface(iface.name))
        for (final addr in iface.addresses)
          if (_isUsableLanIpv4(addr)) addr,
  ];
}

Future<List<InternetAddress>> dropLocalIpv4Addresses() async {
  try {
    final ifaces = await NetworkInterface.list(
      includeLinkLocal: false,
      type: InternetAddressType.IPv4,
    );
    return dropLocalIpv4(ifaces);
  } catch (_) {
    return const [];
  }
}

/// True when [host] sits on the same IPv4 /24 as one of our LAN addresses.
bool dropHostOnLocalLan(InternetAddress host, Iterable<InternetAddress> local) {
  if (host.type != InternetAddressType.IPv4 || host.isLoopback) return false;
  final hb = host.rawAddress;
  if (hb.length != 4) return false;
  for (final addr in local) {
    final b = addr.rawAddress;
    if (b.length != 4) continue;
    if (b[0] == hb[0] && b[1] == hb[1] && b[2] == hb[2]) return true;
  }
  return false;
}

/// Gallery keeps its own peer id, so its hello on this phone looks like
/// another device unless we drop packets from our own LAN addresses.
bool dropHostIsSelf(InternetAddress host, Iterable<InternetAddress> local) {
  if (host.type != InternetAddressType.IPv4) return false;
  final ip = host.address;
  for (final addr in local) {
    if (addr.address == ip) return true;
  }
  return false;
}

bool dropPeerStillHere({
  required InternetAddress host,
  required DateTime lastSeen,
  required DateTime now,
  required Iterable<InternetAddress> local,
  Duration ttl = dropPeerTtl,
}) {
  if (now.difference(lastSeen) > ttl) return false;
  if (dropHostIsSelf(host, local)) return false;
  return dropHostOnLocalLan(host, local);
}

List<InternetAddress> dropBroadcastDestinationsFrom(
  Iterable<InternetAddress> local,
) {
  final map = <String, InternetAddress>{};
  // Prefer subnet broadcasts — global 255.255.255.255 often exits the wrong
  // NIC on Windows (WSL / Hyper-V) and never reaches Wi‑Fi phones.
  for (final addr in local) {
    final dest = subnetBroadcast24(addr);
    if (dest != null) map[dest.address] = dest;
  }
  if (map.isEmpty) {
    map['255.255.255.255'] = InternetAddress('255.255.255.255');
  }
  return map.values.toList();
}

Future<List<InternetAddress>> dropBroadcastDestinations() async {
  return dropBroadcastDestinationsFrom(await dropLocalIpv4Addresses());
}

final _ipv4Literal = RegExp(r'\b(\d{1,3}(?:\.\d{1,3}){3})\b');

bool _looksLikeIpv4(String raw) {
  final parts = raw.split('.');
  if (parts.length != 4) return false;
  for (final part in parts) {
    final n = int.tryParse(part);
    if (n == null || n < 0 || n > 255) return false;
  }
  return true;
}

/// ARP / neighbor-table hosts on the same /24 as [local].
///
/// Wi‑Fi APs often drop Ethernet→wireless *broadcasts* while unicast still
/// works. Unicasting hellos to ARP neighbors keeps phones and desktops visible.
Future<List<InternetAddress>> dropLanNeighborIpv4(
  Iterable<InternetAddress> local,
) async {
  final locals = local
      .where((a) => a.type == InternetAddressType.IPv4)
      .toList(growable: false);
  if (locals.isEmpty) return const [];

  final now = DateTime.now();
  if (_neighborCacheAt != null &&
      now.difference(_neighborCacheAt!) < _neighborCacheTtl) {
    return [
      for (final n in _neighborCache)
        if (dropHostOnLocalLan(n, locals)) n,
    ];
  }

  final found = <String, InternetAddress>{};
  try {
    if (Platform.isWindows) {
      final result = await Process.run('arp', const ['-a']);
      _collectNeighborIps('${result.stdout}', found);
    } else if (Platform.isAndroid || Platform.isLinux) {
      final result = await Process.run('ip', const ['neigh']);
      if (result.exitCode == 0) {
        _collectNeighborIps('${result.stdout}', found);
      } else {
        final arp = await Process.run('arp', const ['-a']);
        _collectNeighborIps('${arp.stdout}', found);
      }
    } else if (Platform.isMacOS) {
      final result = await Process.run('arp', const ['-a']);
      _collectNeighborIps('${result.stdout}', found);
    }
  } catch (_) {}

  final self = {for (final a in locals) a.address};
  final neighbors = <InternetAddress>[
    for (final entry in found.entries)
      if (!self.contains(entry.key) && dropHostOnLocalLan(entry.value, locals))
        entry.value,
  ];
  _neighborCache = neighbors;
  _neighborCacheAt = now;
  return neighbors;
}

void _collectNeighborIps(String text, Map<String, InternetAddress> out) {
  for (final match in _ipv4Literal.allMatches(text)) {
    final raw = match.group(1)!;
    if (!_looksLikeIpv4(raw)) continue;
    if (raw.endsWith('.0') || raw.endsWith('.255')) continue;
    if (raw.startsWith('224.') || raw.startsWith('239.')) continue;
    try {
      out.putIfAbsent(raw, () => InternetAddress(raw));
    } catch (_) {}
  }
}

/// Broadcast + ARP-neighbor unicast targets for a hello packet.
Future<List<InternetAddress>> dropAnnounceDestinations({
  required Iterable<InternetAddress> local,
  Iterable<InternetAddress> knownPeers = const [],
}) async {
  final map = <String, InternetAddress>{
    for (final d in dropBroadcastDestinationsFrom(local)) d.address: d,
  };
  for (final n in await dropLanNeighborIpv4(local)) {
    map[n.address] = n;
  }
  for (final peer in knownPeers) {
    if (peer.type != InternetAddressType.IPv4) continue;
    if (!dropHostOnLocalLan(peer, local)) continue;
    map[peer.address] = peer;
  }
  return map.values.toList();
}
