/// Structured Nearby debug events. No file contents, paths, or payload bytes.
class DropDebugLog {
  DropDebugLog._();

  static const _cap = 160;
  static final List<Map<String, Object?>> _events = [];
  static void Function(String kind)? onSignificant;

  static List<Map<String, Object?>> get events =>
      List<Map<String, Object?>>.unmodifiable(_events);

  static void resetForTest() {
    _events.clear();
    onSignificant = null;
  }

  static void event(String kind, [String? detail]) {
    final row = <String, Object?>{
      't': DateTime.now().toUtc().toIso8601String().substring(11, 19),
      'k': kind,
      if (detail != null && detail.isNotEmpty) 'd': detail,
    };
    _events.add(row);
    if (_events.length > _cap) {
      _events.removeRange(0, _events.length - _cap);
    }
    final significant = kind == 'radio' ||
        kind == 'no_ipv4' ||
        kind == 'scan' ||
        kind == 'perm' ||
        kind == 'resume' ||
        kind == 'opt_in' ||
        kind == 'connect';
    if (significant) onSignificant?.call(kind);
  }
}
