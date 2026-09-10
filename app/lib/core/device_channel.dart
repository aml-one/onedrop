import 'dart:io';

import 'package:flutter/services.dart';

import 'photo_picker_filter.dart';

const _channel = MethodChannel('one.aml.onedrop/device');

class DeviceChannel {
  DeviceChannel._();

  static Future<dynamic> Function(MethodCall)? _appHandler;
  static bool _wired = false;

  static void listen(Future<dynamic> Function(MethodCall call) handler) {
    _appHandler = handler;
    _wire();
  }

  static void _wire() {
    if (_wired) return;
    _wired = true;
    _channel.setMethodCallHandler((call) async {
      return _appHandler?.call(call);
    });
  }

  static Future<void> publishPeers(List<Map<String, Object>> peers) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('publishPeers', {'peers': peers});
    } catch (_) {}
  }

  static Future<bool> isGalleryInstalled() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('isGalleryInstalled') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<List<String>> takePendingShares() async {
    if (!Platform.isAndroid) return const [];
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>('takePendingShares');
      return [
        for (final row in raw ?? const [])
          if (row is String && row.isNotEmpty) row,
      ];
    } catch (_) {
      return const [];
    }
  }

  static Future<bool> handoffMediaToGallery({
    required List<String> paths,
    required List<String> kinds,
  }) async {
    if (!Platform.isAndroid || paths.isEmpty) return false;
    try {
      return await _channel.invokeMethod<bool>('handoffMediaToGallery', {
            'paths': paths,
            'kinds': kinds,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> scanMedia(String path) async {
    if (!Platform.isAndroid || path.isEmpty) return;
    try {
      await _channel.invokeMethod<void>('scanMedia', {'path': path});
    } catch (_) {}
  }

  static Future<void> startOneDropListen() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('startOneDropListen');
    } catch (_) {}
  }

  static Future<void> stopOneDropListen() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('stopOneDropListen');
    } catch (_) {}
  }

  static Future<void> notifyIncomingDrop({
    required String offerId,
    required String peerName,
    required String summary,
  }) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('notifyIncomingDrop', {
        'offerId': offerId,
        'peerName': peerName,
        'summary': summary,
      });
    } catch (_) {}
  }

  static Future<void> cancelIncomingDrop(String offerId) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('cancelIncomingDrop', {
        'offerId': offerId,
      });
    } catch (_) {}
  }

  static Future<void> notifyDropReceived(String message) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('notifyDropReceived', {
        'message': message,
      });
    } catch (_) {}
  }

  static Future<void> ensureFirstRunPermissions() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('ensureFirstRunPermissions');
    } catch (_) {}
  }

  static Future<List<DropPermissionRow>> listPermissions() async {
    if (!Platform.isAndroid) return const [];
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>('listPermissions');
      return [
        for (final row in raw ?? const [])
          if (row is Map) DropPermissionRow.fromMap(row),
      ];
    } catch (_) {
      return const [];
    }
  }

  static Future<bool> requestPermission(String id) async {
    if (!Platform.isAndroid || id.isEmpty) return false;
    try {
      return await _channel.invokeMethod<bool>('requestPermission', {'id': id}) ??
          false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> openAppSettings() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('openAppSettings') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<Map<String, Object?>> debugExtras() async {
    if (!Platform.isAndroid) return const {};
    try {
      final raw = await _channel.invokeMethod<dynamic>('debugExtras');
      if (raw is Map) {
        return {for (final e in raw.entries) '${e.key}': e.value};
      }
    } catch (_) {}
    return const {};
  }

  static Future<String> getDeviceName() async {
    if (!Platform.isAndroid) return '';
    try {
      return await _channel.invokeMethod<String>('getDeviceName') ?? '';
    } catch (_) {
      return '';
    }
  }

  static bool? _tablet;

  /// Last [probeTablet] result. False until probed, and on non-Android.
  static bool get isTabletCached => _tablet == true;

  static void resetForTest() {
    _tablet = null;
  }

  /// Android tablets use the smallest-width ≥ 600 dp qualifier.
  static Future<bool> probeTablet() async {
    if (_tablet != null) return _tablet!;
    if (!Platform.isAndroid) {
      _tablet = false;
      return false;
    }
    try {
      _tablet = await _channel.invokeMethod<bool>('isTablet') ?? false;
    } catch (_) {
      _tablet = false;
    }
    return _tablet!;
  }

  /// MediaStore IS_FAVORITE ids plus Gallery Loved / unloved overrides.
  static Future<PhotoPickerFavoriteSets> listFavoriteSources() async {
    if (!Platform.isAndroid) return const PhotoPickerFavoriteSets();
    try {
      final raw = await _channel.invokeMethod<dynamic>('listFavoriteSources');
      if (raw is! Map) return const PhotoPickerFavoriteSets();
      return PhotoPickerFavoriteSets(
        mediaStore: _idSet(raw['mediaStore']),
        loved: _idSet(raw['galleryLoved']),
        unloved: _idSet(raw['galleryUnloved']),
      );
    } catch (_) {
      return const PhotoPickerFavoriteSets();
    }
  }

  static Set<String> _idSet(Object? raw) {
    if (raw is! List) return const {};
    return {
      for (final row in raw)
        if (row is String && row.isNotEmpty) row,
    };
  }
}

class DropPermissionRow {
  const DropPermissionRow({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.granted,
    required this.canAsk,
    required this.needsSettings,
    required this.action,
  });

  final String id;
  final String title;
  final String subtitle;
  final bool granted;
  final bool canAsk;
  final bool needsSettings;
  final String action;

  factory DropPermissionRow.fromMap(Map<dynamic, dynamic> map) {
    return DropPermissionRow(
      id: '${map['id'] ?? ''}',
      title: '${map['title'] ?? ''}',
      subtitle: '${map['subtitle'] ?? ''}',
      granted: map['granted'] == true,
      canAsk: map['canAsk'] == true,
      needsSettings: map['needsSettings'] == true,
      action: '${map['action'] ?? 'none'}',
    );
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'title': title,
        'granted': granted,
        'canAsk': canAsk,
        'needsSettings': needsSettings,
        'action': action,
      };
}
