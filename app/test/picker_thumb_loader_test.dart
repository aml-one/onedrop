import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:onedrop/core/picker_thumb_loader.dart';

Uint8List _bytes(int value) => Uint8List.fromList([value]);

void main() {
  test('only maxConcurrent decodes start at once', () async {
    final loader = PickerThumbLoader(maxConcurrent: 2);
    final blocked = <String, Completer<Uint8List?>>{
      'a': Completer<Uint8List?>(),
      'b': Completer<Uint8List?>(),
      'c': Completer<Uint8List?>(),
    };
    final started = <String>[];
    for (final id in ['a', 'b', 'c']) {
      loader.load(
        id: id,
        decode: () {
          started.add(id);
          return blocked[id]!.future;
        },
      );
    }
    await Future<void>.value();
    expect(started, ['a', 'b']);
    expect(loader.activeCount, 2);
    expect(loader.waitingCount, 1);

    blocked['a']!.complete(_bytes(1));
    await Future<void>.value();
    await Future<void>.value();
    expect(started, ['a', 'b', 'c']);
  });

  test('cancel drops a waiting job before it decodes', () async {
    final loader = PickerThumbLoader(maxConcurrent: 1);
    final hold = Completer<Uint8List?>();
    final started = <String>[];
    loader.load(
      id: 'hold',
      decode: () {
        started.add('hold');
        return hold.future;
      },
    );
    await Future<void>.value();
    final waiting = loader.load(
      id: 'gone',
      decode: () {
        started.add('gone');
        return Future<Uint8List?>.value(_bytes(2));
      },
    );
    waiting.cancel();
    hold.complete(_bytes(1));
    await Future<void>.value();
    await Future<void>.value();
    expect(started, ['hold']);
    expect(await waiting.future, isNull);
  });

  test('newest visible job jumps older waiting thumbs', () async {
    final loader = PickerThumbLoader(maxConcurrent: 1);
    final hold = Completer<Uint8List?>();
    final started = <String>[];
    loader.load(
      id: 'hold',
      decode: () => hold.future,
    );
    await Future<void>.value();
    loader.load(
      id: 'old',
      decode: () {
        started.add('old');
        return Future<Uint8List?>.value(_bytes(1));
      },
    );
    loader.load(
      id: 'visible',
      decode: () {
        started.add('visible');
        return Future<Uint8List?>.value(_bytes(2));
      },
    );
    hold.complete(_bytes(9));
    await Future<void>.value();
    await Future<void>.value();
    expect(started.first, 'visible');
  });
}
