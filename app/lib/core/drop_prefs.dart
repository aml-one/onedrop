import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'device_channel.dart';
import 'device_name.dart';
import 'host.dart';

enum DropAcceptMode { ask, known, everyone }

class DropKnownPeer {
  const DropKnownPeer({required this.id, required this.name, this.lastAt});

  final String id;
  final String name;
  final DateTime? lastAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (lastAt != null) 'lastAt': lastAt!.toIso8601String(),
      };

  static DropKnownPeer fromJson(Map<String, dynamic> json) => DropKnownPeer(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? 'Device',
        lastAt: DateTime.tryParse(json['lastAt'] as String? ?? ''),
      );
}

class DropPrefs {
  DropPrefs._();

  static const _dropKey = 'drop_accept';
  static const _peerIdKey = 'drop_peer_id';
  static const _knownKey = 'drop_known';
  static const _displayNameKey = 'drop_display_name';
  static const _launchKey = 'launch_at_startup';
  static const _inboxKey = 'inbox_path';
  static const _imagesToGalleryKey = 'images_to_gallery';
  static const _airGrabKey = 'drop_air_grab';
  static const _openExplorerOnReceiveKey = 'open_explorer_on_receive';
  static const _lanIpsKey = 'drop_lan_ips';
  static const _debugUploadKey = 'debug_upload_opt_in';
  static const _debugSessionKey = 'debug_upload_session';
  static const _debugSeqKey = 'debug_upload_seq';

  static SharedPreferences? _prefs;

  static Future<void> ensure() async {
    _prefs ??= await SharedPreferences.getInstance();
    // One Drop on a desk with a native AirGrab camera is a catch surface.
    // Turn AirGrab on the first time unless the user already chose.
    // Linux uses LAN tray transfers for now - no webcam AirGrab yet.
    // Phones keep the old default (off) until Settings says otherwise.
    if (!_prefs!.containsKey(_airGrabKey) && airGrabAvailable) {
      await _prefs!.setBool(_airGrabKey, true);
    }
  }

  /// Native AirGrab camera / catch fog (Windows + macOS today).
  static bool get airGrabAvailable =>
      Platform.isWindows || Platform.isMacOS;

  static void resetForTest() {
    _prefs = null;
    DeviceChannel.resetForTest();
  }

  static String get hostHint => localComputerName();

  /// Phone name (Android) or computer name. Skips the first-run name prompt.
  static Future<String> adoptSystemDisplayName() async {
    await ensure();
    final saved = _prefs!.getString(_displayNameKey)?.trim() ?? '';
    if (saved.isNotEmpty && !isJunkDisplayName(saved)) return saved;
    var system = '';
    if (Platform.isAndroid) {
      await DeviceChannel.probeTablet();
      system = cleanDisplayName(await DeviceChannel.getDeviceName());
    }
    if (isJunkDisplayName(system)) system = hostHint;
    if (isJunkDisplayName(system)) return dropDisplayName;
    await setDropDisplayName(system);
    return system;
  }

  static DropAcceptMode get dropAcceptMode {
    switch (_prefs?.getString(_dropKey)) {
      case 'known':
        return DropAcceptMode.known;
      case 'everyone':
        return DropAcceptMode.everyone;
      default:
        return DropAcceptMode.ask;
    }
  }

  static bool autoAccepts(String peerId) {
    switch (dropAcceptMode) {
      case DropAcceptMode.everyone:
        return true;
      case DropAcceptMode.known:
        return isKnownPeer(peerId);
      case DropAcceptMode.ask:
        return false;
    }
  }

  static bool shouldAutoAccept({
    required String peerId,
    required bool airGrab,
  }) {
    if (airGrab && airGrabEnabled) return true;
    return autoAccepts(peerId);
  }

  static bool get airGrabEnabled {
    if (!airGrabAvailable) return false;
    return _prefs?.getBool(_airGrabKey) ?? true;
  }

  static Future<void> setAirGrabEnabled(bool value) async {
    await ensure();
    await _prefs!.setBool(_airGrabKey, value);
  }

  static Future<void> setDropAcceptMode(DropAcceptMode value) async {
    await ensure();
    await _prefs!.setString(_dropKey, value.name);
  }

  static Future<String> ensurePeerId() async {
    await ensure();
    var id = _prefs!.getString(_peerIdKey);
    if (id == null || id.isEmpty) {
      id = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
      await _prefs!.setString(_peerIdKey, id);
    }
    return id;
  }

  static bool get hasDropDisplayName {
    final raw = _prefs?.getString(_displayNameKey)?.trim();
    return raw != null && raw.isNotEmpty;
  }

  static String get dropDisplayName {
    final raw = _prefs?.getString(_displayNameKey)?.trim();
    if (raw != null && raw.isNotEmpty && !isJunkDisplayName(raw)) return raw;
    return hostHint;
  }

  static Future<void> setDropDisplayName(String name) async {
    await ensure();
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      await _prefs!.remove(_displayNameKey);
      return;
    }
    await _prefs!.setString(_displayNameKey, trimmed);
  }

  static String get defaultInboxPath {
    if (Platform.isAndroid) {
      const root = '/storage/emulated/0';
      for (final name in ['Download', 'Downloads']) {
        final dir = Directory(p.join(root, name));
        if (dir.existsSync()) return p.join(dir.path, 'OneDrop');
      }
      return p.join(root, 'Download', 'OneDrop');
    }
    final home = Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        '';
    if (home.isEmpty) return p.join('Downloads', 'OneDrop');
    return p.join(home, 'Downloads', 'OneDrop');
  }

  /// Photos and videos land here when [imagesToCameraRoll] is off.
  static String get mediaInboxPath {
    if (Platform.isAndroid) {
      return p.join('/storage/emulated/0', 'Pictures', 'OneDrop');
    }
    final home = Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        '';
    if (home.isEmpty) return p.join('Pictures', 'OneDrop');
    return p.join(home, 'Pictures', 'OneDrop');
  }

  /// Same folder the phone camera writes into (not the AmL Gallery app).
  static const androidCameraRollPath = '/storage/emulated/0/DCIM/Camera';

  static String get cameraRollPath {
    if (!Platform.isAndroid) return mediaInboxPath;
    return androidCameraRollPath;
  }

  /// Photos and videos. On a phone this is the camera roll or Pictures/OneDrop.
  /// On a PC there is no camera roll — they go in the receive folder.
  static String get mediaSavePath {
    if (!Platform.isAndroid) return inboxPath;
    return imagesToCameraRoll ? cameraRollPath : mediaInboxPath;
  }

  static String get inboxPath {
    final raw = _prefs?.getString(_inboxKey)?.trim();
    if (raw != null && raw.isNotEmpty) return raw;
    return defaultInboxPath;
  }

  static String get inboxShortLabel {
    final parts = p.split(inboxPath).where((part) => part.isNotEmpty).toList();
    if (parts.length <= 2) return inboxPath;
    return p.join(parts[parts.length - 2], parts.last);
  }

  static Future<void> setInboxPath(String path) async {
    await ensure();
    final trimmed = path.trim();
    if (trimmed.isEmpty) {
      await _prefs!.remove(_inboxKey);
      return;
    }
    await _prefs!.setString(_inboxKey, trimmed);
  }

  /// Incoming photos and videos go in the camera roll (default) or
  /// Pictures/OneDrop. Pref key kept so a prior on/off choice still maps.
  static bool get imagesToCameraRoll =>
      _prefs?.getBool(_imagesToGalleryKey) ?? true;

  static Future<void> setImagesToCameraRoll(bool value) async {
    await ensure();
    await _prefs!.setBool(_imagesToGalleryKey, value);
  }

  /// Desktop only: open the system file manager after a received drop.
  /// Defaults on for the tray clients so a finished drop shows the inbox.
  static bool get openExplorerOnReceive =>
      _prefs?.getBool(_openExplorerOnReceiveKey) ?? isDesktopTray;

  static Future<void> setOpenExplorerOnReceive(bool value) async {
    await ensure();
    await _prefs!.setBool(_openExplorerOnReceiveKey, value);
  }

  static bool get launchAtStartup => _prefs?.getBool(_launchKey) ?? false;

  static Future<void> setLaunchAtStartup(bool value) async {
    await ensure();
    await _prefs!.setBool(_launchKey, value);
  }

  /// Opt-in Nearby debug uploads to aml.one. Off until the user turns it on.
  static bool get debugUploadOptIn => _prefs?.getBool(_debugUploadKey) ?? false;

  static String get debugUploadSession =>
      _prefs?.getString(_debugSessionKey)?.trim() ?? '';

  static int get debugUploadSeq => _prefs?.getInt(_debugSeqKey) ?? 0;

  static Future<void> setDebugUploadOptIn(bool value) async {
    await ensure();
    if (!value) {
      await _prefs!.setBool(_debugUploadKey, false);
      await _prefs!.remove(_debugSessionKey);
      await _prefs!.setInt(_debugSeqKey, 0);
      return;
    }
    await _prefs!.setBool(_debugUploadKey, true);
    if (debugUploadSession.isEmpty) {
      final stamp = DateTime.now().toUtc().microsecondsSinceEpoch.toRadixString(16);
      await _prefs!.setString(_debugSessionKey, stamp);
    }
  }

  static Future<int> bumpDebugUploadSeq() async {
    await ensure();
    final next = debugUploadSeq + 1;
    await _prefs!.setInt(_debugSeqKey, next);
    return next;
  }

  /// Last LAN IPv4s we heard a hello from. Ethernet PCs unicast here because
  /// Xiaomi / ColorOS APs often drop wired→Wi‑Fi broadcasts, and ARP forgets
  /// a quiet phone within minutes.
  static List<InternetAddress> get rememberedLanIpv4 {
    final raw = _prefs?.getStringList(_lanIpsKey);
    if (raw == null || raw.isEmpty) return const [];
    final out = <InternetAddress>[];
    for (final row in raw) {
      final ip = row.trim();
      if (ip.isEmpty) continue;
      try {
        final addr = InternetAddress(ip);
        if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
          out.add(addr);
        }
      } catch (_) {}
    }
    return out;
  }

  static Future<void> rememberLanIpv4(InternetAddress addr) async {
    if (addr.type != InternetAddressType.IPv4 || addr.isLoopback) return;
    if (addr.address == '0.0.0.0') return;
    await ensure();
    final current = _prefs!.getStringList(_lanIpsKey) ?? const <String>[];
    if (current.isNotEmpty && current.first == addr.address) return;
    final next = <String>[
      addr.address,
      for (final ip in current)
        if (ip != addr.address) ip,
    ];
    if (next.length > 16) next.removeRange(16, next.length);
    await _prefs!.setStringList(_lanIpsKey, next);
  }

  static List<DropKnownPeer> get knownPeers {
    final raw = _prefs?.getString(_knownKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map(
            (row) =>
                DropKnownPeer.fromJson(Map<String, dynamic>.from(row as Map)),
          )
          .toList();
    } catch (_) {
      return const [];
    }
  }

  static bool isKnownPeer(String peerId) =>
      knownPeers.any((peer) => peer.id == peerId);

  static Future<void> rememberPeer(DropKnownPeer peer) async {
    await ensure();
    final next = [peer, ...knownPeers.where((item) => item.id != peer.id)];
    await _prefs!.setString(
      _knownKey,
      jsonEncode(next.map((item) => item.toJson()).toList()),
    );
  }

  static Future<void> forgetPeer(String peerId) async {
    await ensure();
    final next = knownPeers.where((item) => item.id != peerId).toList();
    await _prefs!.setString(
      _knownKey,
      jsonEncode(next.map((item) => item.toJson()).toList()),
    );
  }
}
