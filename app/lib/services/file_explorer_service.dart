import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

const kFileExplorerMaxEntries = 2000;
const _lastFolderKey = 'file_explorer_last_folder';
const _sortKey = 'file_explorer_sort';

enum FileExplorerSortField { name, date }

enum FileExplorerSortDirection { ascending, descending }

class FileExplorerSort {
  const FileExplorerSort({
    this.field = FileExplorerSortField.name,
    this.direction = FileExplorerSortDirection.ascending,
  });

  static const nameAsc = FileExplorerSort();

  final FileExplorerSortField field;
  final FileExplorerSortDirection direction;

  String get persistValue => '${field.name}_${direction.name}';

  FileExplorerSort copyWith({
    FileExplorerSortField? field,
    FileExplorerSortDirection? direction,
  }) {
    return FileExplorerSort(
      field: field ?? this.field,
      direction: direction ?? this.direction,
    );
  }

  static FileExplorerSort parse(String? raw) {
    return switch (raw) {
      'name_descending' => const FileExplorerSort(
        field: FileExplorerSortField.name,
        direction: FileExplorerSortDirection.descending,
      ),
      'date_ascending' => const FileExplorerSort(
        field: FileExplorerSortField.date,
      ),
      'date_descending' => const FileExplorerSort(
        field: FileExplorerSortField.date,
        direction: FileExplorerSortDirection.descending,
      ),
      _ => nameAsc,
    };
  }

  @override
  bool operator ==(Object other) =>
      other is FileExplorerSort &&
      other.field == field &&
      other.direction == direction;

  @override
  int get hashCode => Object.hash(field, direction);
}

class FileExplorerEntry {
  const FileExplorerEntry({
    required this.path,
    required this.name,
    required this.isDirectory,
    required this.sizeBytes,
    this.modifiedMs = 0,
  });

  final String path;
  final String name;
  final bool isDirectory;
  final int sizeBytes;
  final int modifiedMs;
}

class FileExplorerShortcut {
  const FileExplorerShortcut({
    required this.id,
    required this.label,
    required this.path,
  });

  final String id;
  final String label;
  final String path;
}

bool get fileExplorerSupported => !kIsWeb && !Platform.isIOS;

/// Folder names that are safe to create under [parent].
String? sanitizeFileExplorerFolderName(String raw) {
  var name = raw.trim();
  if (name.isEmpty) return null;
  if (name.contains('/') || name.contains(r'\') || name.contains('\u0000')) {
    return null;
  }
  name = name.replaceAll(RegExp(r'[<>:"|?*]'), '').trim();
  if (name.isEmpty || name == '.' || name == '..') return null;
  return name;
}

Directory? createFileExplorerFolder(String parent, String rawName) {
  final name = sanitizeFileExplorerFolderName(rawName);
  if (name == null) return null;
  final dir = Directory(p.join(parent, name));
  if (dir.existsSync()) return dir;
  try {
    dir.createSync();
    return dir;
  } catch (_) {
    return null;
  }
}

Future<List<FileExplorerEntry>> listFileExplorerDirectory(
  String directory, {
  Set<String>? allowedExtensions,
  int maxEntries = kFileExplorerMaxEntries,
  FileExplorerSort sort = FileExplorerSort.nameAsc,
}) {
  return compute(listFileExplorerDirectorySync, <String, Object?>{
    'directory': directory,
    'allowedExtensions': allowedExtensions?.toList(growable: false),
    'maxEntries': maxEntries,
    'sort': sort.persistValue,
  });
}

/// Isolate / test entry — keep top-level for [compute].
List<FileExplorerEntry> listFileExplorerDirectorySync(
  Map<String, Object?> args,
) {
  final directory = args['directory']! as String;
  final maxEntries = (args['maxEntries'] as int?) ?? kFileExplorerMaxEntries;
  final allowed = (args['allowedExtensions'] as List?)
      ?.cast<String>()
      .map((value) => value.toLowerCase().replaceFirst('.', ''))
      .toSet();
  final entries = <FileExplorerEntry>[];

  for (final entity in Directory(directory).listSync(followLinks: false)) {
    final name = p.basename(entity.path);
    if (name.startsWith('.')) continue;
    final isDirectory = entity is Directory;
    if (!isDirectory && entity is! File) continue;
    if (!isDirectory &&
        allowed != null &&
        allowed.isNotEmpty &&
        !allowed.contains(
          p.extension(name).toLowerCase().replaceFirst('.', ''),
        )) {
      continue;
    }
    var size = 0;
    var modifiedMs = 0;
    try {
      final stat = entity.statSync();
      modifiedMs = stat.modified.millisecondsSinceEpoch;
      if (!isDirectory) size = stat.size;
    } catch (_) {}
    entries.add(
      FileExplorerEntry(
        path: entity.path,
        name: name,
        isDirectory: isDirectory,
        sizeBytes: size,
        modifiedMs: modifiedMs,
      ),
    );
  }

  final sorted = sortFileExplorerEntries(
    entries,
    FileExplorerSort.parse(args['sort'] as String?),
  );
  return sorted.take(maxEntries).toList(growable: false);
}

/// Folders stay first; [sort] applies inside each group.
List<FileExplorerEntry> sortFileExplorerEntries(
  List<FileExplorerEntry> entries,
  FileExplorerSort sort,
) {
  final out = List<FileExplorerEntry>.from(entries);
  out.sort((a, b) {
    if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
    final cmp = switch (sort.field) {
      FileExplorerSortField.name =>
        a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      FileExplorerSortField.date => a.modifiedMs.compareTo(b.modifiedMs),
    };
    if (cmp != 0) {
      return sort.direction == FileExplorerSortDirection.ascending ? cmp : -cmp;
    }
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
  return out;
}

String? fileExplorerHome({Map<String, String>? environment}) {
  final env = environment ?? Platform.environment;
  if (!kIsWeb && Platform.isWindows) {
    final profile = env['USERPROFILE']?.trim();
    if (profile != null && profile.isNotEmpty) return p.normalize(profile);
    final drive = env['HOMEDRIVE']?.trim() ?? '';
    final path = env['HOMEPATH']?.trim() ?? '';
    if (drive.isNotEmpty && path.isNotEmpty) {
      return p.normalize('$drive$path');
    }
    return null;
  }
  final home = env['HOME']?.trim();
  if (home == null || home.isEmpty) return null;
  return p.normalize(home);
}

String fileExplorerDefaultRoot({
  Map<String, String>? environment,
  bool Function(String path)? exists,
}) {
  final has = exists ?? (path) => Directory(path).existsSync();
  if (!kIsWeb && Platform.isAndroid) {
    const primary = '/storage/emulated/0';
    if (has(primary)) return primary;
    const sdcard = '/sdcard';
    if (has(sdcard)) return p.normalize(sdcard);
  }
  return fileExplorerHome(environment: environment) ??
      (Platform.isWindows ? r'C:\' : '/');
}

List<FileExplorerShortcut> fileExplorerShortcuts({
  Map<String, String>? environment,
  bool Function(String path)? exists,
}) {
  final has = exists ?? (path) => Directory(path).existsSync();
  final env = environment ?? Platform.environment;
  final home = fileExplorerHome(environment: env);
  final root = fileExplorerDefaultRoot(environment: env, exists: has);
  final out = <FileExplorerShortcut>[];
  final seen = <String>{};

  void add(String id, String label, String? raw) {
    final value = raw?.trim() ?? '';
    if (value.isEmpty) return;
    final normalized = p.normalize(value);
    if (!has(normalized) || !seen.add(normalized)) return;
    out.add(FileExplorerShortcut(id: id, label: label, path: normalized));
  }

  String? joinHome(String name) =>
      home == null ? null : p.join(home, name);

  if (!kIsWeb && Platform.isAndroid) {
    add('internal', 'internal', root);
    add('download', 'downloads', p.join(root, 'Download'));
    add('downloads', 'downloads', p.join(root, 'Downloads'));
    add('documents', 'documents', p.join(root, 'Documents'));
    add('pictures', 'pictures', p.join(root, 'Pictures'));
    add('movies', 'videos', p.join(root, 'Movies'));
    add('dcim', 'dcim', p.join(root, 'DCIM'));
    add('music', 'music', p.join(root, 'Music'));
    return out;
  }

  add('downloads', 'downloads', joinHome('Downloads'));
  add('documents', 'documents', joinHome('Documents'));
  add('pictures', 'pictures', joinHome('Pictures'));
  add('videos', 'videos', joinHome('Videos'));
  add('movies', 'videos', joinHome('Movies'));
  add('music', 'music', joinHome('Music'));
  add('pictures_xdg', 'pictures', _xdgDir(env, 'XDG_PICTURES_DIR', home));
  add('videos_xdg', 'videos', _xdgDir(env, 'XDG_VIDEOS_DIR', home));
  add('download_xdg', 'downloads', _xdgDir(env, 'XDG_DOWNLOAD_DIR', home));
  add('docs_xdg', 'documents', _xdgDir(env, 'XDG_DOCUMENTS_DIR', home));
  add('music_xdg', 'music', _xdgDir(env, 'XDG_MUSIC_DIR', home));
  return out;
}

String? desktopLibraryDirectoryFor({
  required String type,
  Map<String, String>? environment,
  bool Function(String path)? exists,
}) {
  if (type != 'image' && type != 'video') return null;
  final has = exists ?? (path) => Directory(path).existsSync();
  final env = environment ?? Platform.environment;
  final home = fileExplorerHome(environment: env);
  final candidates = <String?>[];
  if (type == 'image') {
    if (home != null) candidates.add(p.join(home, 'Pictures'));
    candidates.add(_xdgDir(env, 'XDG_PICTURES_DIR', home));
  } else {
    if (home != null) {
      candidates.add(p.join(home, 'Videos'));
      candidates.add(p.join(home, 'Movies'));
    }
    candidates.add(_xdgDir(env, 'XDG_VIDEOS_DIR', home));
  }
  for (final raw in candidates) {
    final value = raw?.trim() ?? '';
    if (value.isEmpty) continue;
    final normalized = p.normalize(value);
    if (has(normalized)) return normalized;
  }
  return null;
}

String uniquePathInDirectory(String dir, String fileName) {
  final sep = Platform.pathSeparator;
  var candidate = '$dir$sep$fileName';
  if (!File(candidate).existsSync()) return candidate;
  final ext = p.extension(fileName);
  final base = ext.isEmpty
      ? fileName
      : fileName.substring(0, fileName.length - ext.length);
  for (var i = 1; i < 1000; i++) {
    final next = ext.isEmpty ? '${base}_$i' : '${base}_$i$ext';
    candidate = '$dir$sep$next';
    if (!File(candidate).existsSync()) return candidate;
  }
  return '$dir$sep${DateTime.now().millisecondsSinceEpoch}_$fileName';
}

Future<String?> loadLastFileExplorerFolder() async {
  final prefs = await SharedPreferences.getInstance();
  final path = prefs.getString(_lastFolderKey)?.trim();
  if (path == null || path.isEmpty) return null;
  if (!Directory(path).existsSync()) return null;
  return p.normalize(path);
}

Future<void> saveLastFileExplorerFolder(String path) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_lastFolderKey, p.normalize(path));
}

Future<FileExplorerSort> loadFileExplorerSort() async {
  final prefs = await SharedPreferences.getInstance();
  return FileExplorerSort.parse(prefs.getString(_sortKey));
}

Future<void> saveFileExplorerSort(FileExplorerSort sort) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_sortKey, sort.persistValue);
}

Future<bool> ensureFileExplorerStorageAccess() async {
  if (!fileExplorerSupported) return false;
  if (!Platform.isAndroid) return true;
  if (await Permission.manageExternalStorage.isGranted) return true;
  final manage = await Permission.manageExternalStorage.request();
  if (manage.isGranted) return true;
  if (await Permission.storage.isGranted) return true;
  final storage = await Permission.storage.request();
  return storage.isGranted;
}

String? _xdgDir(Map<String, String> env, String key, String? home) {
  var value = env[key]?.trim() ?? '';
  if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
    value = value.substring(1, value.length - 1);
  }
  if (home != null && home.isNotEmpty) {
    value = value.replaceAll(r'${HOME}', home).replaceAll(r'$HOME', home);
  }
  if (value.isEmpty) return null;
  return p.normalize(value);
}
