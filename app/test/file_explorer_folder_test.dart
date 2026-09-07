import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:onedrop/services/file_explorer_service.dart';
import 'package:path/path.dart' as p;

void main() {
  test('folder names reject path tricks', () {
    expect(sanitizeFileExplorerFolderName('Vacation'), 'Vacation');
    expect(sanitizeFileExplorerFolderName('  Photos  '), 'Photos');
    expect(sanitizeFileExplorerFolderName('../secret'), isNull);
    expect(sanitizeFileExplorerFolderName('a/b'), isNull);
    expect(sanitizeFileExplorerFolderName('.'), isNull);
    expect(sanitizeFileExplorerFolderName(''), isNull);
  });

  test('createFileExplorerFolder makes a subfolder', () {
    final parent = Directory.systemTemp.createTempSync('onedrop-folder-');
    addTearDown(() {
      if (parent.existsSync()) parent.deleteSync(recursive: true);
    });
    final created = createFileExplorerFolder(parent.path, 'New album');
    expect(created, isNotNull);
    expect(created!.existsSync(), isTrue);
    expect(p.basename(created.path), 'New album');
  });
}
