import 'package:flutter_test/flutter_test.dart';
import 'package:onedrop/core/labels.dart';

void main() {
  test('kindForPath tells photos, videos, and files apart', () {
    expect(isImagePath('sunset.jpg'), isTrue);
    expect(isVideoPath(r'C:\clip.MP4'), isTrue);
    expect(kindForPath('notes.pdf'), 'file');
    expect(kindForPath('clip.mov'), 'video');
    expect(kindForPath('pic.HEIC'), 'image');
  });
}
