// Keep the One Drop wire protocol in sync with
// gallery/app/lib/services/drop_service.dart (UDP 4071, HTTP /drop/*).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:air_gesture/air_gesture.dart';
import 'package:drop_p2p/drop_p2p.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

import '../core/device_channel.dart';
import '../core/drop_prefs.dart';
import '../core/host.dart';
import '../core/labels.dart';
import 'drop_debug_log.dart';
import 'drop_lan.dart';

Map<String, dynamic> _decodeOfferResponse(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) {
    throw StateError('No response from peer');
  }
  try {
    final decoded = jsonDecode(trimmed);
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
  } on FormatException {
    // Older peers (desktop One Drop) reply with plain text like "too_large".
  }
  final lower = trimmed.toLowerCase();
  if (lower == 'too_large' || lower.contains('too_large')) {
    throw StateError(dropTooLargeMessage());
  }
  if (lower == 'bad_offer' || lower.contains('bad_offer')) {
    throw StateError('Could not send this file');
  }
  throw StateError('Could not send');
}


class DropPeer {
  const DropPeer({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.lastSeen,
    this.role = AirPeerRole.phone,
    this.os = AirPeerOs.other,
    this.camera = false,
    this.attention = 0,
    this.seesHand = false,
    this.aimPeerId,
    this.holdingCount,
    this.holdingKind,
    this.viaRadio = false,
    this.app = AirDropApp.gallery,
  });

  final String id;
  final String name;
  final InternetAddress host;
  final int port;
  final DateTime lastSeen;
  final AirPeerRole role;
  final AirPeerOs os;
  final bool camera;
  final double attention;
  final bool seesHand;
  final String? aimPeerId;
  final int? holdingCount;
  final String? holdingKind;
  final bool viaRadio;
  final AirDropApp app;

  bool get acceptsFiles => app == AirDropApp.onedrop;

  bool get isHolding => (holdingCount ?? 0) > 0;

  bool aimsAt(String peerId) =>
      peerId.isNotEmpty && aimPeerId != null && aimPeerId == peerId;

  AirDropPeer get airPeer => AirDropPeer(
        id: id,
        name: name,
        role: role,
        os: os,
        camera: camera,
        attention: attention,
        seesHand: seesHand,
      );
}

String? dropAimPeerId(dynamic raw) {
  final id = raw is String ? raw.trim() : '';
  return id.isEmpty ? null : id;
}

class DropOffer {
  DropOffer({
    required this.id,
    required this.peerId,
    required this.peerName,
    required this.files,
    required this.from,
    this.airGrab = false,
  });

  final String id;
  final String peerId;
  final String peerName;
  final List<DropFileInfo> files;
  final InternetAddress from;
  final bool airGrab;
  Completer<bool>? decision;
}

class DropCancelled implements Exception {}

class DropDeclined implements Exception {
  @override
  String toString() => 'They declined this One Drop';
}

enum DropSendPhase { waiting, sending, done }

class DropSendProgress {
  const DropSendProgress({
    required this.phase,
    required this.label,
    required this.fraction,
    this.peerName = '',
  });

  final DropSendPhase phase;
  final String label;
  final double fraction;
  final String peerName;
}

class DropReceiveProgress {
  const DropReceiveProgress({
    required this.offerId,
    required this.peerName,
    required this.receivedBytes,
    required this.totalBytes,
    required this.fileIndex,
    required this.fileCount,
    this.done = false,
  });

  final String offerId;
  final String peerName;
  final int receivedBytes;
  final int totalBytes;
  final int fileIndex;
  final int fileCount;
  final bool done;

  double get fraction {
    if (done) return 1;
    if (totalBytes <= 0) return 0;
    return (receivedBytes / totalBytes).clamp(0.0, 1.0);
  }

  int get percent => (fraction * 100).round();
}

int dropOfferTotalBytes(List<DropFileInfo> files) {
  return files.fold<int>(0, (sum, file) => sum + file.size);
}

int dropOfferPriorBytes(List<DropFileInfo> files, int index) {
  var n = 0;
  final last = index.clamp(0, files.length);
  for (var i = 0; i < last; i++) {
    n += files[i].size;
  }
  return n;
}

class DropSendCancelToken {
  bool _cancelled = false;
  HttpClient? _client;
  final Completer<void> _aborted = Completer<void>();

  bool get isCancelled => _cancelled;

  Future<void> get whenCancelled => _aborted.future;

  void bind(HttpClient client) => _client = client;

  void cancel() {
    _cancelled = true;
    try {
      _client?.close(force: true);
    } catch (_) {}
    if (!_aborted.isCompleted) _aborted.complete();
  }
}

/// [HttpClient.close] often leaves [HttpClientRequest.close] hanging on
/// Android while the other device still holds `/drop/offer`. Race the
/// work against [DropSendCancelToken.whenCancelled] so Cancel returns now.
Future<T> _awaitOrCancel<T>(
  Future<T> work,
  DropSendCancelToken? cancel,
) {
  if (cancel == null) return work;
  if (cancel.isCancelled) {
    unawaited(work.then<void>((_) {}, onError: (_) {}));
    return Future<T>.error(DropCancelled());
  }
  final done = Completer<T>();
  var settled = false;
  void fail(Object error, [StackTrace? stack]) {
    if (settled) return;
    settled = true;
    done.completeError(error, stack ?? StackTrace.current);
  }

  work.then(
    (value) {
      if (settled) return;
      settled = true;
      done.complete(value);
    },
    onError: fail,
  );
  unawaited(
    cancel.whenCancelled.then(
      (_) => fail(DropCancelled()),
      onError: fail,
    ),
  );
  return done.future;
}

const _dropSendReadBytes = 512 * 1024;

Stream<List<int>> _dropFileChunks(File file) async* {
  final raf = await file.open();
  try {
    while (true) {
      final chunk = await raf.read(_dropSendReadBytes);
      if (chunk.isEmpty) break;
      yield chunk;
    }
  } finally {
    await raf.close();
  }
}

class DropFileInfo {
  const DropFileInfo({
    required this.name,
    required this.kind,
    required this.size,
  });

  final String name;
  final String kind;
  final int size;

  Map<String, dynamic> toJson() => {'name': name, 'kind': kind, 'size': size};

  static DropFileInfo fromJson(Map<String, dynamic> json) => DropFileInfo(
        name: json['name'] as String? ?? 'photo.jpg',
        kind: normalizeDropKind(json['kind'] as String?),
        size: (json['size'] as num?)?.toInt() ?? 0,
      );
}

class DropReceivedBatch {
  const DropReceivedBatch({
    required this.message,
    required this.paths,
    required this.peerName,
    this.airGrab = false,
  });

  final String message;
  final List<String> paths;
  final String peerName;
  /// True when the peer sent via AirGrab (aim/catch). LAN One Drop stays false.
  final bool airGrab;
}

class DropOutgoing {
  const DropOutgoing({
    required this.file,
    required this.name,
    required this.kind,
  });

  final File file;
  final String name;
  final String kind;
}

class DropService {
  DropService._();
  static final instance = DropService._();

  static const udpPort = 4071;
  static const maxFile = dropMaxFileBytes;
  static const maxFiles = dropMaxFiles;

  HttpServer? _http;
  RawDatagramSocket? _udp;
  Timer? _announce;
  Timer? _prune;
  StreamSubscription<DropP2pSighting>? _radio;
  int _httpPort = 0;
  String _peerId = '';
  bool _running = false;
  bool _lanListed = false;
  List<InternetAddress> _localIpv4 = const [];
  String? lastError;
  String _lastPeersKey = '';
  final _debugLog = <String>[];

  final _peers = <String, DropPeer>{};
  final _offers = <String, DropOffer>{};
  final peers = StreamController<List<DropPeer>>.broadcast();
  final incoming = StreamController<DropOffer>.broadcast();
  final received = StreamController<DropReceivedBatch>.broadcast();
  final Map<String, List<String>> _savedByOffer = {};
  final receiving = StreamController<DropReceiveProgress>.broadcast();
  final catches = StreamController<DropPeer>.broadcast();
  DropReceiveProgress? currentReceive;
  DateTime _receiveEmitAt = DateTime.fromMillisecondsSinceEpoch(0);
  final _abortedOffers = <String>{};
  StreamSubscription<List<int>>? _incomingFileSub;
  StreamController<List<int>>? _incomingChunks;
  File? _incomingTemp;
  bool _cameraCapable = false;
  bool _seesHand = false;
  double _attention = 0;
  DateTime _attentionAt = DateTime.fromMillisecondsSinceEpoch(0);
  AirHolding? _holding;
  String? _aimPeerId;

  bool get running => _running;
  String get peerId => _peerId;
  bool get cameraCapable => _cameraCapable;
  bool get seesHand => _seesHand;
  AirHolding? get holding => _holding;
  List<DropPeer> get peerList => _peers.values.toList();
  int get debugHttpPort => _httpPort;
  List<String> get debugIpv4 => [
        for (final address in _localIpv4) address.address,
      ];
  List<String> get debugLog => List<String>.unmodifiable(_debugLog);

  AirPeerRole get localRole {
    if (!isPhoneSurface) return AirPeerRole.desktop;
    if (DeviceChannel.isTabletCached) return AirPeerRole.tablet;
    return AirPeerRole.phone;
  }

  AirPeerOs get localOs {
    if (Platform.isAndroid) return AirPeerOs.android;
    if (Platform.isWindows) return AirPeerOs.windows;
    if (Platform.isMacOS) return AirPeerOs.macos;
    if (Platform.isLinux) return AirPeerOs.linux;
    return AirPeerOs.other;
  }

  void setCameraCapable(bool value) {
    if (_cameraCapable == value) return;
    _cameraCapable = value;
    announceNow();
  }

  void setHolding(AirHolding? next) {
    final same = (_holding?.count == next?.count) &&
        (_holding?.kind == next?.kind);
    if (same) return;
    _holding = next;
    announceNow();
  }

  void setAttention(double value) {
    final next = value.clamp(0.0, 1.0);
    final flipped = (next >= kLookingAttention) != (_attention >= kLookingAttention);
    if (!flipped && (next - _attention).abs() < 0.08) return;
    final now = DateTime.now();
    if (!flipped && now.difference(_attentionAt) < const Duration(milliseconds: 180)) {
      return;
    }
    _attention = next;
    _attentionAt = now;
    announceNow();
  }

  void setSeesHand(bool value) {
    if (_seesHand == value) return;
    _seesHand = value;
    announceNow();
  }

  void setAim(String? peerId) {
    final next = (peerId == null || peerId.isEmpty) ? null : peerId;
    if (_aimPeerId == next) return;
    _aimPeerId = next;
    announceNow();
  }

  void sendCatch(DropPeer peer) {
    if (!_running || _udp == null) return;
    final payload = utf8.encode(
      jsonEncode({
        'v': 1,
        'type': 'catch',
        'peerId': _peerId,
        'toPeerId': peer.id,
      }),
    );
    _udp?.send(payload, peer.host, udpPort);
  }

  Future<void> start() async {
    if (_running) return;
    if (Platform.environment['FLUTTER_TEST'] == 'true') return;
    try {
      lastError = null;
      await DeviceChannel.probeTablet();
      _peerId = await DropPrefs.ensurePeerId();
      _httpPort = await _bindHttp();
      _localIpv4 = await dropLocalIpv4Addresses();
      _note(
        'start peer=$_peerId http=$_httpPort ipv4=${debugIpv4.join(',')}',
      );
      if (_localIpv4.isEmpty) {
        _note('no ipv4 — UDP announce will wait for Wi‑Fi');
        DropDebugLog.event('no_ipv4');
      }
      _udp = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        udpPort,
        reuseAddress: true,
        reusePort: Platform.isMacOS,
      );
      _udp!.broadcastEnabled = true;
      _udp!.listen(_onUdp);
      _announce = Timer.periodic(const Duration(seconds: 2), (_) => _broadcast());
      _prune = Timer.periodic(const Duration(seconds: 4), (_) {
        unawaited(refreshLan());
      });
      _running = true;
      await refreshLan();
      _broadcast();
      if (DropP2p.supported) {
        await _startRadio();
      } else {
        _note('radio unsupported on this OS');
      }
    } catch (error) {
      lastError = '$error';
      _note('start failed $error');
      await stop();
    }
  }

  Future<void> restartRadio() async {
    if (!DropP2p.supported || !_running || _httpPort <= 0) return;
    await _startRadio();
  }

  Future<void> _startRadio() async {
    _radio ??= DropP2p.sightings.listen(_onRadio);
    await DropP2p.start(
      peerId: _peerId,
      name: DropPrefs.dropDisplayName,
      port: _httpPort,
      role: airRoleWire(localRole),
      os: airOsWire(localOs),
      files: true,
    );
    await DropP2p.setScanHard(true);
    if (DropP2p.lastError == null) {
      _note('radio start ok');
    } else {
      _note('radio start ${DropP2p.lastError}');
      DropDebugLog.event('radio', DropP2p.lastError);
    }
  }

  void announceNow() {
    if (_running) _broadcast();
  }

  Future<void> stop() async {
    _running = false;
    _announce?.cancel();
    _prune?.cancel();
    await _radio?.cancel();
    _radio = null;
    await DropP2p.setScanHard(false);
    await DropP2p.stop();
    _udp?.close();
    await _http?.close(force: true);
    _http = null;
    _udp = null;
    _peers.clear();
    _lastPeersKey = '';
    _lanListed = false;
    _localIpv4 = const [];
    _emitPeers();
  }

  void _note(String line) {
    final stamp = DateTime.now().toUtc().toIso8601String().substring(11, 19);
    _debugLog.add('$stamp $line');
    if (_debugLog.length > 160) {
      _debugLog.removeRange(0, _debugLog.length - 160);
    }
  }

  String _peersKey() {
    final rows = [
      for (final peer in peerList)
        '${peer.id}|${peer.name}|${peer.host.address}|${peer.port}|${peer.viaRadio}|${peer.app.name}',
    ]..sort();
    return rows.join(';');
  }

  void _emitPeers() {
    final key = _peersKey();
    if (key == _lastPeersKey) return;
    _lastPeersKey = key;
    peers.add(peerList);
    unawaited(DeviceChannel.publishPeers([
      for (final peer in peerList)
        if (peer.port > 0 &&
            peer.host.address.isNotEmpty &&
            peer.host.address != '0.0.0.0')
          {
            'id': peer.id,
            'name': peer.name,
            'host': peer.host.address,
            'port': peer.port,
          },
    ]));
  }

  /// Re-read LAN addresses and drop peers that are no longer on this Wi‑Fi.
  Future<void> refreshLan() async {
    _localIpv4 = await dropLocalIpv4Addresses();
    _lanListed = true;
    _expirePeers();
  }

  Future<void> send(
    DropPeer peer,
    List<DropOutgoing> items, {
    DropSendCancelToken? cancel,
    void Function(DropSendProgress progress)? onProgress,
    bool airGrab = false,
  }) async {
    final files = <({DropFileInfo info, File file})>[];
    for (final item in items.take(maxFiles)) {
      if (!item.file.existsSync()) continue;
      final size = item.file.lengthSync();
      if (size <= 0 || size > maxFile) continue;
      files.add((
        info: DropFileInfo(name: item.name, kind: item.kind, size: size),
        file: item.file,
      ));
    }
    if (files.isEmpty) throw StateError('Nothing to send');
    if (cancel?.isCancelled == true) throw DropCancelled();

    final totalBytes = files.fold<int>(0, (sum, file) => sum + file.info.size);
    var sentBytes = 0;
    var lastEmit = DateTime.fromMillisecondsSinceEpoch(0);

    void emit(DropSendProgress progress, {bool force = false}) {
      final now = DateTime.now();
      if (!force && now.difference(lastEmit) < const Duration(milliseconds: 80)) {
        return;
      }
      lastEmit = now;
      onProgress?.call(progress);
    }

    void sendingLabel(int index, {bool force = false}) {
      emit(
        DropSendProgress(
          phase: DropSendPhase.sending,
          peerName: peer.name,
          fraction: totalBytes <= 0 ? 0 : sentBytes / totalBytes,
          label: files.length == 1
              ? 'Sending'
              : 'Sending ${index + 1} of ${files.length}',
        ),
        force: force,
      );
    }

    final client = HttpClient()
      ..autoUncompress = false
      ..idleTimeout = const Duration(minutes: 30)
      ..connectionTimeout = const Duration(seconds: 20);
    cancel?.bind(client);
    var radio = peer.viaRadio;
    var target = peer;
    try {
      if (radio) {
        emit(
          DropSendProgress(
            phase: DropSendPhase.waiting,
            peerName: peer.name,
            fraction: 0,
            label: 'Opening a private Wi-Fi link…',
          ),
          force: true,
        );
        final link = await _awaitOrCancel(DropP2p.connect(peer.id), cancel);
        if (cancel?.isCancelled == true) throw DropCancelled();
        target = DropPeer(
          id: peer.id,
          name: peer.name,
          host: InternetAddress(link.host),
          port: link.port,
          lastSeen: peer.lastSeen,
          role: peer.role,
          os: peer.os,
          camera: peer.camera,
          attention: peer.attention,
          seesHand: peer.seesHand,
          aimPeerId: peer.aimPeerId,
          holdingCount: peer.holdingCount,
          holdingKind: peer.holdingKind,
          viaRadio: peer.viaRadio,
          app: peer.app,
        );
      }
      emit(
        DropSendProgress(
          phase: DropSendPhase.waiting,
          peerName: peer.name,
          fraction: 0,
          label: 'Waiting for ${peer.name} to accept',
        ),
        force: true,
      );
      final origin = 'http://${target.host.address}:${target.port}';
      final offer = await _awaitOrCancel(
        client.postUrl(Uri.parse('$origin/drop/offer')),
        cancel,
      );
      if (cancel?.isCancelled == true) throw DropCancelled();
      offer.headers.contentType = ContentType.json;
      offer.add(
        utf8.encode(
          jsonEncode({
            'peerId': _peerId,
            'name': DropPrefs.dropDisplayName,
            'files': [for (final f in files) f.info.toJson()],
            if (airGrab) 'airGrab': true,
          }),
        ),
      );
      final offered = await _awaitOrCancel(offer.close(), cancel);
      if (cancel?.isCancelled == true) throw DropCancelled();
      final body = _decodeOfferResponse(
        await _awaitOrCancel(offered.transform(utf8.decoder).join(), cancel),
      );
      if (body['accept'] != true) {
        final err = '${body['error'] ?? ''}'.trim().toLowerCase();
        if (err == 'too_large' || err == 'too large') {
          throw StateError(dropTooLargeMessage());
        }
        throw DropDeclined();
      }
      final offerId = body['offerId'] as String;
      for (var i = 0; i < files.length; i++) {
        if (cancel?.isCancelled == true) throw DropCancelled();
        sendingLabel(i, force: true);
        final put = await _awaitOrCancel(
          client.putUrl(Uri.parse('$origin/drop/offer/$offerId/file/$i')),
          cancel,
        );
        put.headers.contentLength = files[i].info.size;
        var fileSent = 0;
        await _awaitOrCancel(
          put.addStream(
            _dropFileChunks(files[i].file).map((chunk) {
              if (cancel?.isCancelled == true) {
                throw DropCancelled();
              }
              fileSent += chunk.length;
              sentBytes = files.take(i).fold<int>(0, (n, f) => n + f.info.size) +
                  fileSent;
              sendingLabel(i);
              return chunk;
            }),
          ),
          cancel,
        );
        final done = await _awaitOrCancel(put.close(), cancel);
        if (done.statusCode != 200) {
          throw StateError('Transfer failed on ${files[i].info.name}');
        }
        sentBytes = files.take(i + 1).fold<int>(0, (n, f) => n + f.info.size);
      }
      emit(
        DropSendProgress(
          phase: DropSendPhase.done,
          peerName: peer.name,
          fraction: 1,
          label: 'Sent to ${peer.name}',
        ),
        force: true,
      );
    } on DropCancelled {
      rethrow;
    } on DropDeclined {
      rethrow;
    } catch (error) {
      if (cancel?.isCancelled == true) throw DropCancelled();
      rethrow;
    } finally {
      if (radio) await DropP2p.teardown();
      client.close(force: true);
    }
  }

  Future<int> _bindHttp() async {
    final app = Router()
      ..get('/drop/hello', (Request req) {
        return Response.ok(
          jsonEncode({
            'peerId': _peerId,
            'name': DropPrefs.dropDisplayName,
            'protocol': 1,
          }),
          headers: {'content-type': 'application/json'},
        );
      })
      ..post('/drop/offer', _onOffer)
      ..put('/drop/offer/<id>/file/<index>', _onFile);
    _http = await shelf_io.serve(app.call, InternetAddress.anyIPv4, 0);
    _http!.idleTimeout = const Duration(minutes: 30);
    return _http!.port;
  }

  Future<Response> _onOffer(Request request) async {
    final json = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final peerId = json['peerId'] as String? ?? '';
    final name = json['name'] as String? ?? 'One Drop';
    final files = [
      for (final row in (json['files'] as List? ?? const []))
        DropFileInfo.fromJson(Map<String, dynamic>.from(row as Map)),
    ];
    if (peerId.isEmpty || files.isEmpty || files.length > maxFiles) {
      return Response.badRequest(
        body: jsonEncode({'accept': false, 'error': 'bad_offer'}),
        headers: {'content-type': 'application/json'},
      );
    }
    if (files.any((f) => f.size <= 0 || f.size > maxFile)) {
      return Response.badRequest(
        body: jsonEncode({'accept': false, 'error': 'too_large'}),
        headers: {'content-type': 'application/json'},
      );
    }
    final from = request.context['shelf.io.connection_info'] is HttpConnectionInfo
        ? (request.context['shelf.io.connection_info'] as HttpConnectionInfo)
            .remoteAddress
        : InternetAddress.loopbackIPv4;
    final airGrab = json['airGrab'] == true;
    final offer = DropOffer(
      id: DateTime.now().microsecondsSinceEpoch.toRadixString(16),
      peerId: peerId,
      peerName: name,
      files: files,
      from: from,
      airGrab: airGrab,
    );
    final auto = DropPrefs.shouldAutoAccept(
      peerId: peerId,
      airGrab: airGrab,
    );
    if (auto) {
      _offers[offer.id] = offer;
      _publishReceive(offer, 0, dropOfferTotalBytes(offer.files), 0, force: true);
      unawaited(
        DropPrefs.rememberPeer(
          DropKnownPeer(id: peerId, name: name, lastAt: DateTime.now()),
        ),
      );
      return Response.ok(
        jsonEncode({'offerId': offer.id, 'accept': true}),
        headers: {'content-type': 'application/json'},
      );
    }
    offer.decision = Completer<bool>();
    _offers[offer.id] = offer;
    incoming.add(offer);
    final accepted = await offer.decision!.future.timeout(
      const Duration(seconds: 60),
      onTimeout: () => false,
    );
    if (!accepted) {
      _offers.remove(offer.id);
      return Response.ok(
        jsonEncode({'offerId': offer.id, 'accept': false}),
        headers: {'content-type': 'application/json'},
      );
    }
    unawaited(
      DropPrefs.rememberPeer(
        DropKnownPeer(id: peerId, name: name, lastAt: DateTime.now()),
      ),
    );
    return Response.ok(
      jsonEncode({'offerId': offer.id, 'accept': true}),
      headers: {'content-type': 'application/json'},
    );
  }

  Future<Response> _onFile(Request request, String id, String indexRaw) async {
    if (_abortedOffers.contains(id)) {
      return Response(409, body: 'cancelled');
    }
    final offer = _offers[id];
    if (offer == null) return Response.notFound('missing');
    final index = int.tryParse(indexRaw) ?? -1;
    if (index < 0 || index >= offer.files.length) {
      return Response.badRequest(body: 'bad_index');
    }
    final info = offer.files[index];
    final total = dropOfferTotalBytes(offer.files);
    final prior = dropOfferPriorBytes(offer.files, index);
    var current = 0;
    _publishReceive(offer, prior, total, index, force: true);
    final tempDir = await getTemporaryDirectory();
    final temp = File(
      p.join(
        tempDir.path,
        'onedrop-recv-${offer.id}-$index-${p.basename(info.name)}',
      ),
    );
    IOSink? sink;
    final chunks = StreamController<List<int>>();
    _incomingChunks = chunks;
    _incomingTemp = temp;
    _incomingFileSub = request.read().listen(
      chunks.add,
      onError: chunks.addError,
      onDone: () {
        if (!chunks.isClosed) unawaited(chunks.close());
      },
    );
    try {
      if (_abortedOffers.contains(id)) throw DropCancelled();
      final out = temp.openWrite();
      sink = out;
      await for (final chunk in chunks.stream) {
        if (_abortedOffers.contains(id)) throw DropCancelled();
        current += chunk.length;
        if (current > maxFile) {
          await out.close();
          sink = null;
          if (temp.existsSync()) temp.deleteSync();
          return Response.badRequest(
            body: jsonEncode({'accept': false, 'error': 'too_large'}),
            headers: {'content-type': 'application/json'},
          );
        }
        out.add(chunk);
        _publishReceive(offer, prior + current, total, index);
      }
      if (_abortedOffers.contains(id)) throw DropCancelled();
      await out.flush();
      await out.close();
      sink = null;
    } on DropCancelled {
      try {
        await sink?.close();
      } catch (_) {}
      if (temp.existsSync()) {
        try {
          temp.deleteSync();
        } catch (_) {}
      }
      return Response(409, body: 'cancelled');
    } catch (_) {
      try {
        await sink?.close();
      } catch (_) {}
      if (temp.existsSync()) {
        try {
          temp.deleteSync();
        } catch (_) {}
      }
      rethrow;
    } finally {
      await _incomingFileSub?.cancel();
      _incomingFileSub = null;
      if (!chunks.isClosed) await chunks.close();
      if (identical(_incomingChunks, chunks)) _incomingChunks = null;
      if (identical(_incomingTemp, temp)) _incomingTemp = null;
    }
    final length = temp.existsSync() ? temp.lengthSync() : 0;
    if (length <= 0 || length > maxFile) {
      if (temp.existsSync()) temp.deleteSync();
      return Response.badRequest(
        body: jsonEncode({'accept': false, 'error': 'too_large'}),
        headers: {'content-type': 'application/json'},
      );
    }
    final saved = await DropInbox.saveFile(temp, info);
    (_savedByOffer[id] ??= []).add(saved.path);
    if (temp.existsSync()) {
      try {
        temp.deleteSync();
      } catch (_) {}
    }
    if (index == offer.files.length - 1) {
      _offers.remove(id);
      _publishReceive(offer, total, total, index, force: true, done: true);
      final paths = _savedByOffer.remove(id) ?? const <String>[];
      received.add(
        DropReceivedBatch(
          message: _receivedMessage(offer: offer),
          paths: paths,
          peerName: offer.peerName,
          airGrab: offer.airGrab,
        ),
      );
    } else {
      _publishReceive(
        offer,
        prior + info.size,
        total,
        index + 1,
        force: true,
      );
    }
    return Response.ok(
      jsonEncode({'ok': true}),
      headers: {'content-type': 'application/json'},
    );
  }

  void _publishReceive(
    DropOffer offer,
    int received,
    int total,
    int fileIndex, {
    bool force = false,
    bool done = false,
  }) {
    final now = DateTime.now();
    if (!force &&
        !done &&
        now.difference(_receiveEmitAt).inMilliseconds < 50) {
      return;
    }
    _receiveEmitAt = now;
    final progress = DropReceiveProgress(
      offerId: offer.id,
      peerName: offer.peerName,
      receivedBytes: total <= 0 ? received : received.clamp(0, total),
      totalBytes: total,
      fileIndex: fileIndex.clamp(0, offer.files.length),
      fileCount: offer.files.length,
      done: done,
    );
    currentReceive = progress;
    receiving.add(progress);
  }

  void decide(DropOffer offer, bool accept) {
    final pending = offer.decision;
    if (pending == null || pending.isCompleted) return;
    pending.complete(accept);
    if (accept) {
      _publishReceive(
        offer,
        0,
        dropOfferTotalBytes(offer.files),
        0,
        force: true,
      );
    }
  }

  /// Drop a stuck or in-flight receive and return to nearby.
  void abortReceive() {
    final id = currentReceive?.offerId;
    if (id != null) {
      _abortedOffers.add(id);
      final offer = _offers.remove(id);
      final pending = offer?.decision;
      if (pending != null && !pending.isCompleted) {
        pending.complete(false);
      }
      _savedByOffer.remove(id);
    }
    final sub = _incomingFileSub;
    _incomingFileSub = null;
    unawaited(sub?.cancel());
    final chunks = _incomingChunks;
    _incomingChunks = null;
    if (chunks != null && !chunks.isClosed) {
      chunks.addError(DropCancelled());
      unawaited(chunks.close());
    }
    final temp = _incomingTemp;
    _incomingTemp = null;
    if (temp != null && temp.existsSync()) {
      try {
        temp.deleteSync();
      } catch (_) {}
    }
    currentReceive = null;
  }

  void _onUdp(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final packet = _udp?.receive();
    if (packet == null) return;
    try {
      final json = jsonDecode(utf8.decode(packet.data)) as Map<String, dynamic>;
      if (json['v'] != 1) return;
      final id = json['peerId'] as String? ?? '';
      if (id.isEmpty || id == _peerId) return;
      if (dropHostIsSelf(packet.address, _localIpv4)) return;
      if (json['type'] == 'catch') {
        if (json['toPeerId'] != _peerId) return;
        if (!dropShouldAcceptLanHello(packet.address, _localIpv4)) {
          return;
        }
        final holder = _peers[id];
        if (holder != null) catches.add(holder);
        return;
      }
      final port = (json['port'] as num?)?.toInt() ?? 0;
      if (port <= 0) return;
      if (!dropShouldAcceptLanHello(packet.address, _localIpv4)) {
        return;
      }
      final holding = AirHolding.fromJson(json['holding']);
      final existing = _peers[id];
      final isNew = existing == null;
      _peers[id] = DropPeer(
        id: id,
        name: json['name'] as String? ?? 'One Drop',
        host: packet.address,
        port: port,
        lastSeen: DateTime.now(),
        role: parseAirRole(json['role']),
        os: parseAirOs(json['os']),
        camera: json['camera'] == true,
        attention: attentionFromWire(json['attention']),
        seesHand: json['hand'] == true,
        aimPeerId: dropAimPeerId(json['aim']),
        holdingCount: holding?.count,
        holdingKind: holding?.kind,
        app: mergeAirApp(existing?.app, helloApp: json['app']),
      );
      _emitPeers();
      if (isNew) _note('wifi peer ${json['name'] ?? id}');
      unawaited(DropPrefs.rememberLanIpv4(packet.address));
      _sendHello(packet.address);
    } catch (_) {}
  }

  List<int> _helloBytes() {
    return utf8.encode(
      jsonEncode({
        'v': 1,
        'peerId': _peerId,
        'name': DropPrefs.dropDisplayName,
        'port': _httpPort,
        'role': airRoleWire(localRole),
        'os': airOsWire(localOs),
        'camera': _cameraCapable,
        'attention': attentionToWire(_attention),
        'hand': _seesHand,
        'aim': _aimPeerId,
        'holding': _holding?.toJson(),
        'app': airAppWire(AirDropApp.onedrop),
      }),
    );
  }

  void _sendHello(InternetAddress dest) {
    if (!_running || _udp == null) return;
    if (!dropIsUsableLanIpv4(dest)) return;
    _udp!.send(_helloBytes(), dest, udpPort);
  }

  Future<void> _broadcast() async {
    _localIpv4 = await dropLocalIpv4Addresses();
    _lanListed = true;
    _expirePeers();
    if (!_running || _udp == null || _localIpv4.isEmpty) return;
    final payload = _helloBytes();
    final known = <InternetAddress>[
      for (final peer in _peers.values)
        if (dropIsUsableLanIpv4(peer.host)) peer.host,
    ];
    for (final dest in await dropAnnounceDestinations(
      local: _localIpv4,
      knownPeers: known,
      remembered: DropPrefs.rememberedLanIpv4,
    )) {
      _udp?.send(payload, dest, udpPort);
    }
  }

  void _onRadio(DropP2pSighting row) {
    if (!_running || row.peerId == _peerId) return;
    final existing = _peers[row.peerId];
    if (existing != null && !existing.viaRadio) {
      // Keep the LAN address (needed to send) but treat BLE as a heartbeat
      // so a quiet UDP window does not yank them off Nearby.
      _peers[row.peerId] = DropPeer(
        id: existing.id,
        name: existing.name,
        host: existing.host,
        port: existing.port,
        lastSeen: DateTime.now(),
        role: existing.role,
        os: existing.os,
        camera: existing.camera,
        attention: existing.attention,
        seesHand: existing.seesHand,
        aimPeerId: existing.aimPeerId,
        holdingCount: existing.holdingCount,
        holdingKind: existing.holdingKind,
        viaRadio: existing.viaRadio,
        app: mergeAirApp(existing.app, filesCapable: row.files),
      );
      _emitPeers();
      return;
    }
    final isNew = existing == null;
    _peers[row.peerId] = DropPeer(
      id: row.peerId,
      name: row.name,
      host: InternetAddress.anyIPv4,
      port: row.port,
      lastSeen: DateTime.now(),
      role: parseAirRole(row.role),
      os: parseAirOs(row.os),
      viaRadio: true,
      app: mergeAirApp(existing?.app, filesCapable: row.files),
    );
    _emitPeers();
    if (isNew) _note('ble peer ${row.name}');
  }

  void _expirePeers() {
    final now = DateTime.now();
    final lost = <String>[];
    _peers.removeWhere((_, peer) {
      final gone = peer.viaRadio
          ? now.difference(peer.lastSeen) > dropRadioPeerTtl
          : !dropPeerStillHere(
              host: peer.host,
              lastSeen: peer.lastSeen,
              now: now,
              local: _localIpv4,
            );
      if (gone) {
        lost.add('${peer.name}${peer.viaRadio ? ' ble' : ' wifi'}');
      }
      return gone;
    });
    if (lost.isNotEmpty) _note('lost ${lost.join(', ')}');
    _emitPeers();
  }

  String _receivedMessage({required DropOffer offer}) {
    final payload = dropPayloadLabel(
      photos: offer.files
          .where((f) => normalizeDropKind(f.kind) == dropKindImage)
          .length,
      videos: offer.files
          .where((f) => normalizeDropKind(f.kind) == dropKindVideo)
          .length,
      files: offer.files.where((f) => dropKindIsFile(f.kind)).length,
    );
    return 'Received $payload from ${offer.peerName}';
  }
}

class DropInbox {
  DropInbox._();

  static Future<Directory> directory({bool files = false}) async {
    final path = files || !Platform.isAndroid
        ? DropPrefs.inboxPath
        : DropPrefs.mediaSavePath;
    var dir = Directory(path);
    try {
      if (!dir.existsSync()) dir.createSync(recursive: true);
      return dir;
    } catch (_) {}
    final home = Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        (await getApplicationDocumentsDirectory()).parent.path;
    final folder = files || !Platform.isAndroid
        ? p.join(home, 'Downloads', 'OneDrop')
        : p.join(home, 'Pictures', 'OneDrop');
    dir = Directory(folder);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  static Future<File> _uniqueDest(DropFileInfo info) async {
    final dir = await directory(files: dropKindIsFile(info.kind));
    var name = info.name.trim().isEmpty ? 'photo.jpg' : info.name.trim();
    name = p.basename(name);
    var dest = File(p.join(dir.path, name));
    if (dest.existsSync()) {
      final stem = p.basenameWithoutExtension(name);
      final ext = p.extension(name);
      dest = File(
        p.join(
          dir.path,
          '$stem-${DateTime.now().millisecondsSinceEpoch}$ext',
        ),
      );
    }
    return dest;
  }

  static Future<void> save(Uint8List bytes, DropFileInfo info) async {
    final dest = await _uniqueDest(info);
    await dest.writeAsBytes(bytes, flush: true);
    await DeviceChannel.scanMedia(dest.path);
  }

  static Future<File> saveFile(File file, DropFileInfo info) async {
    final dest = await _uniqueDest(info);
    await file.copy(dest.path);
    await DeviceChannel.scanMedia(dest.path);
    return dest;
  }

  static DateTime? _openedAt;
  static String? _openedKey;
  static const _openGate = Duration(seconds: 2);

  /// Opens the receive inbox (Downloads/OneDrop by default) in the
  /// system file manager. Pass [path] to open a specific folder.
  static Future<void> open({String? path}) async {
    final dir = path != null
        ? Directory(path)
        : await directory(files: true);
    if (!dir.existsSync()) {
      try {
        dir.createSync(recursive: true);
      } catch (_) {}
    }
    await openFolderInExplorer(dir.path);
  }

  /// One Explorer window for a received batch, even when many files land.
  static Future<void> openReceived(Iterable<String> paths) async {
    await openOnce(dropRevealFolder(paths));
  }

  static Future<void> openOnce(String path) async {
    final now = DateTime.now();
    final key = folderKey(path);
    if (_openedKey == key &&
        _openedAt != null &&
        now.difference(_openedAt!) < _openGate) {
      return;
    }
    _openedKey = key;
    _openedAt = now;
    await open(path: path);
  }

  @visibleForTesting
  static void resetOpenGateForTest() {
    _openedAt = null;
    _openedKey = null;
  }
}

typedef OpenFolderInExplorer = Future<void> Function(String path);

Future<void> defaultOpenFolderInExplorer(String path) async {
  final native = p.normalize(path);
  final dir = Directory(native);
  if (!dir.existsSync()) {
    dir.createSync(recursive: true);
  }
  try {
    if (Platform.isWindows) {
      // Bare `explorer C:\folder` often no-ops on Windows 11 when a
      // shell window already exists. `start "" folder` uses the folder
      // verb and brings a window forward.
      final folder = native.replaceAll('/', r'\');
      await Process.run('cmd.exe', ['/c', 'start', '', folder]);
    } else if (Platform.isMacOS) {
      await Process.start(
        'open',
        [native],
        mode: ProcessStartMode.detached,
      );
    } else {
      await Process.start(
        'xdg-open',
        [native],
        mode: ProcessStartMode.detached,
      );
    }
  } catch (_) {}
}

@visibleForTesting
OpenFolderInExplorer openFolderInExplorer = defaultOpenFolderInExplorer;

String folderKey(String path) {
  var n = p.normalize(path);
  if (n.length > 1 && (n.endsWith('/') || n.endsWith('\\'))) {
    n = n.substring(0, n.length - 1);
  }
  return Platform.isWindows ? n.toLowerCase() : n;
}

/// One folder to reveal for a drop. Same parent → that folder. Mixed
/// inbox + pictures → inbox if any file landed there, else the first.
String dropRevealFolder(Iterable<String> paths, {String? inbox}) {
  final inboxPath = inbox ?? DropPrefs.inboxPath;
  final inboxKey = folderKey(inboxPath);
  final byKey = <String, String>{};
  for (final path in paths) {
    final trimmed = path.trim();
    if (trimmed.isEmpty) continue;
    final dir = p.normalize(p.dirname(trimmed));
    byKey.putIfAbsent(folderKey(dir), () => dir);
  }
  if (byKey.isEmpty) return inboxPath;
  if (byKey.length == 1) return byKey.values.first;
  if (byKey.containsKey(inboxKey)) return inboxPath;
  return byKey.values.first;
}

/// Desktop auto-open: at most one file-manager window per received batch.
Future<void> revealReceivedBatch(DropReceivedBatch batch) async {
  if (!isDesktopTray) return;
  if (!DropPrefs.openExplorerOnReceive) return;
  if (batch.airGrab) return;
  if (batch.paths.isEmpty) return;
  await DropInbox.openReceived(batch.paths);
}

List<DropOutgoing> outgoingFromPaths(Iterable<String> paths) {
  return [
    for (final path in paths)
      if (File(path).existsSync())
        DropOutgoing(
          file: File(path),
          name: p.basename(path),
          kind: kindForPath(path),
        ),
  ];
}
