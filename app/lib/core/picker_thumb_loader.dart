import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

/// Bounded thumbnail decode queue, same idea as Gallery [ThumbCache._gate].
///
/// Visible cells enqueue as priority. A fast fling still *builds* off-screen
/// tiles, but those tickets cancel on dispose before they take a decode slot,
/// so the tiles on screen jump the queue.
class PickerThumbLoader {
  PickerThumbLoader({this.maxConcurrent = 4});

  static final PickerThumbLoader instance = PickerThumbLoader();

  final int maxConcurrent;

  final Map<String, Uint8List> _mem = {};
  final List<_PickerThumbJob> _priority = [];
  final List<_PickerThumbJob> _background = [];
  int _active = 0;

  @visibleForTesting
  int get activeCount => _active;

  @visibleForTesting
  int get waitingCount => _priority.length + _background.length;

  Uint8List? peek(String id) => _mem[id];

  PickerThumbTicket load({
    required String id,
    required Future<Uint8List?> Function() decode,
    bool priority = true,
  }) {
    final hit = _mem[id];
    if (hit != null) {
      return PickerThumbTicket._immediate(hit);
    }
    final job = _PickerThumbJob(id: id, decode: decode, loader: this);
    (priority ? _priority : _background).add(job);
    _pump();
    return PickerThumbTicket._(job);
  }

  void _cancel(_PickerThumbJob job) {
    if (job.started || job.completer.isCompleted) return;
    _priority.remove(job);
    _background.remove(job);
    job.cancelled = true;
    if (!job.completer.isCompleted) {
      job.completer.complete(null);
    }
    _pump();
  }

  void _pump() {
    while (_active < maxConcurrent && _priority.isNotEmpty) {
      _run(_priority.removeLast());
    }
    while (_active < maxConcurrent &&
        _priority.isEmpty &&
        _background.isNotEmpty) {
      _run(_background.removeAt(0));
    }
  }

  void _run(_PickerThumbJob job) {
    if (job.cancelled || job.completer.isCompleted) {
      _pump();
      return;
    }
    job.started = true;
    _active++;
    () async {
      try {
        final cached = _mem[job.id];
        if (cached != null) {
          if (!job.completer.isCompleted) job.completer.complete(cached);
          return;
        }
        final bytes = await job.decode();
        if (bytes != null && bytes.isNotEmpty) {
          _mem[job.id] = bytes;
        }
        if (!job.completer.isCompleted) {
          job.completer.complete(bytes);
        }
      } catch (_) {
        if (!job.completer.isCompleted) {
          job.completer.complete(null);
        }
      } finally {
        _active--;
        _pump();
      }
    }();
  }

  @visibleForTesting
  void resetForTest() {
    _mem.clear();
    _priority.clear();
    _background.clear();
    _active = 0;
  }
}

class PickerThumbTicket {
  PickerThumbTicket._(_PickerThumbJob job)
      : _job = job,
        future = job.completer.future;

  PickerThumbTicket._immediate(Uint8List bytes)
      : _job = null,
        future = Future<Uint8List?>.value(bytes);

  final _PickerThumbJob? _job;
  final Future<Uint8List?> future;

  void cancel() {
    final job = _job;
    if (job == null) return;
    job.loader._cancel(job);
  }
}

class _PickerThumbJob {
  _PickerThumbJob({
    required this.id,
    required this.decode,
    required this.loader,
  });

  final String id;
  final Future<Uint8List?> Function() decode;
  final PickerThumbLoader loader;
  final Completer<Uint8List?> completer = Completer<Uint8List?>();
  bool cancelled = false;
  bool started = false;
}
