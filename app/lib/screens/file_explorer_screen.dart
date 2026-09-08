import 'dart:async';
import 'dart:io';

import 'package:aml_ui/aml_ui.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/file_explorer_kind.dart';
import '../core/file_explorer_l10n.dart';
import '../services/file_explorer_service.dart';
import '../widgets/file_explorer_icon.dart';

enum FileExplorerMode { pickFile, pickFolder }

Future<String?> pickFileExplorerFile(
  BuildContext context, {
  String? title,
  Set<String>? allowedExtensions,
}) async {
  final paths = await pickFileExplorerFiles(
    context,
    title: title,
    allowMultiple: false,
    allowedExtensions: allowedExtensions,
  );
  return paths?.firstOrNull;
}

Future<List<String>?> pickFileExplorerFiles(
  BuildContext context, {
  String? title,
  bool allowMultiple = false,
  Set<String>? allowedExtensions,
}) {
  if (!fileExplorerSupported) return Future.value(null);
  return Navigator.of(context).push<List<String>>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => FileExplorerScreen(
        mode: FileExplorerMode.pickFile,
        title: title,
        allowMultiple: allowMultiple,
        allowedExtensions: allowedExtensions,
      ),
    ),
  );
}

Future<String?> pickFileExplorerFolder(
  BuildContext context, {
  String? title,
  String? initialPath,
}) {
  if (!fileExplorerSupported) return Future.value(null);
  return Navigator.of(context).push<String>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => FileExplorerScreen(
        mode: FileExplorerMode.pickFolder,
        title: title,
        initialPath: initialPath,
      ),
    ),
  );
}

class FileExplorerScreen extends StatefulWidget {
  const FileExplorerScreen({
    super.key,
    required this.mode,
    this.title,
    this.allowMultiple = false,
    this.allowedExtensions,
    this.initialPath,
  });

  final FileExplorerMode mode;
  final String? title;
  final bool allowMultiple;
  final Set<String>? allowedExtensions;
  final String? initialPath;

  @override
  State<FileExplorerScreen> createState() => _FileExplorerScreenState();
}

class _FileExplorerScreenState extends State<FileExplorerScreen> {
  late final String _rootPath;
  late String _currentPath;
  List<FileExplorerEntry> _entries = const [];
  List<FileExplorerShortcut> _shortcuts = const [];
  final Set<String> _selected = {};
  bool _loading = true;
  bool _needsAccess = false;
  String? _error;
  int _loadGeneration = 0;
  FileExplorerSort _sort = FileExplorerSort.nameAsc;

  bool get _atRoot => p.equals(_currentPath, _rootPath);
  bool get _pickFolder => widget.mode == FileExplorerMode.pickFolder;

  @override
  void initState() {
    super.initState();
    _rootPath = fileExplorerDefaultRoot();
    _currentPath = _rootPath;
    _shortcuts = fileExplorerShortcuts();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final granted = await ensureFileExplorerStorageAccess();
    if (!mounted) return;
    if (!granted) {
      setState(() {
        _needsAccess = true;
        _loading = false;
      });
      return;
    }
    final last = await loadLastFileExplorerFolder();
    final sort = await loadFileExplorerSort();
    if (!mounted) return;
    final start = _usableStart(widget.initialPath) ?? last;
    if (start != null) _currentPath = start;
    _sort = sort;
    await _load();
  }

  String? _usableStart(String? path) {
    final raw = path?.trim() ?? '';
    if (raw.isEmpty) return null;
    var dir = Directory(raw);
    if (!dir.existsSync()) {
      dir = Directory(p.dirname(raw));
    }
    if (!dir.existsSync()) return null;
    final normalized = p.normalize(dir.path);
    final root = p.normalize(_rootPath);
    if (p.equals(normalized, root)) return normalized;
    if (!p.isWithin(root, normalized)) return null;
    return normalized;
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    setState(() {
      _loading = true;
      _error = null;
      _needsAccess = false;
      _entries = const [];
      _selected.clear();
    });
    try {
      final entries = await listFileExplorerDirectory(
        _currentPath,
        allowedExtensions: widget.allowedExtensions,
        sort: _sort,
      );
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _entries = entries;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _loading = false;
        _error = fileExplorerL10n.fileExplorerCannotOpen;
      });
    }
  }

  void _openDirectory(String path) {
    _currentPath = p.normalize(path);
    _load();
  }

  void _goBack() {
    if (_selected.isNotEmpty) {
      setState(_selected.clear);
      return;
    }
    if (_atRoot) {
      Navigator.of(context).pop();
      return;
    }
    final parent = p.dirname(_currentPath);
    if (parent == _currentPath) {
      Navigator.of(context).pop();
      return;
    }
    _openDirectory(parent);
  }

  Future<void> _rememberCurrent() => saveLastFileExplorerFolder(_currentPath);

  void _pick(FileExplorerEntry entry) {
    if (entry.isDirectory) {
      _openDirectory(entry.path);
      return;
    }
    if (_pickFolder) return;
    if (!widget.allowMultiple) {
      unawaited(_rememberCurrent());
      Navigator.of(context).pop(<String>[entry.path]);
      return;
    }
    setState(() {
      if (!_selected.add(entry.path)) _selected.remove(entry.path);
    });
  }

  void _confirmFolder() {
    unawaited(_rememberCurrent());
    Navigator.of(context).pop(_currentPath);
  }

  Future<void> _createFolder() async {
    const l10n = fileExplorerL10n;
    final name = await showDialog<String>(
      context: context,
      builder: (context) => _NewFolderDialog(l10n: l10n),
    );
    if (!mounted || name == null) return;
    final created = createFileExplorerFolder(_currentPath, name);
    if (created == null) return;
    _openDirectory(created.path);
  }

  void _confirmMulti() {
    if (_selected.isEmpty) return;
    unawaited(_rememberCurrent());
    Navigator.of(context).pop(_selected.toList(growable: false));
  }

  void _setSort(FileExplorerSort next) {
    if (next == _sort) return;
    setState(() => _sort = next);
    unawaited(saveFileExplorerSort(next));
    if (_entries.length >= kFileExplorerMaxEntries) {
      unawaited(_load());
      return;
    }
    setState(() => _entries = sortFileExplorerEntries(_entries, next));
  }

  Future<void> _showSortSheet() {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        child: _FileExplorerSortSheet(
          sort: _sort,
          onChanged: _setSort,
        ),
      ),
    );
  }

  String _shortcutLabel(FileExplorerShortcut shortcut) {
    const l10n = fileExplorerL10n;
    return switch (shortcut.label) {
      'downloads' => l10n.fileExplorerShortcutDownloads,
      'documents' => l10n.fileExplorerShortcutDocuments,
      'pictures' => l10n.fileExplorerShortcutPictures,
      'videos' => l10n.fileExplorerShortcutVideos,
      'music' => l10n.fileExplorerShortcutMusic,
      'dcim' => l10n.fileExplorerShortcutDcim,
      'internal' => l10n.fileExplorerShortcutInternal,
      _ => shortcut.label,
    };
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  List<({String label, String path})> _crumbs() {
    final crumbs = <({String label, String path})>[];
    var path = _currentPath;
    while (true) {
      final atRoot = p.equals(path, _rootPath);
      final base = p.basename(path);
      crumbs.add((
        label: atRoot
            ? (_rootPath.contains('emulated/0') || _rootPath == '/sdcard'
                ? fileExplorerL10n.fileExplorerShortcutInternal
                : (base.isEmpty ? fileExplorerL10n.fileExplorerTitle : base))
            : (base.isEmpty ? path : base),
        path: path,
      ));
      if (atRoot) break;
      final parent = p.dirname(path);
      if (parent == path) break;
      path = parent;
    }
    return crumbs.reversed.toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    const l10n = fileExplorerL10n;
    final title = widget.title ??
        (_pickFolder ? l10n.fileExplorerChooseFolder : l10n.fileExplorerTitle);
    final canPopRoute = _atRoot && _selected.isEmpty;
    return PopScope(
      canPop: canPopRoute,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _goBack();
      },
      child: SettingsPageScaffold(
        title: title,
        actions: [
          IconButton(
            tooltip: l10n.fileExplorerSort,
            onPressed: _needsAccess || _loading ? null : _showSortSheet,
            icon: const Icon(Icons.sort_rounded),
          ),
          if (_pickFolder) ...[
            IconButton(
              tooltip: l10n.fileExplorerNewFolder,
              onPressed: _needsAccess || _loading ? null : _createFolder,
              icon: const Icon(Icons.create_new_folder_outlined),
            ),
            TextButton(
              onPressed: _needsAccess || _loading ? null : _confirmFolder,
              child: Text(l10n.fileExplorerSaveHere),
            ),
          ],
          if (!_pickFolder && widget.allowMultiple)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 12, 8),
              child: FilledButton(
                onPressed: _selected.isEmpty ? null : _confirmMulti,
                style: FilledButton.styleFrom(
                  backgroundColor: AmlTheme.violet,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor:
                      AmlTheme.violet.withValues(alpha: 0.28),
                  disabledForegroundColor: Colors.white.withValues(alpha: 0.85),
                  minimumSize: const Size(72, 36),
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                ),
                child: Text(
                  _selected.isEmpty
                      ? l10n.fileExplorerSend
                      : '${l10n.fileExplorerSend} (${_selected.length})',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ),
        ],
        body: Column(
          children: [
            _Breadcrumb(crumbs: _crumbs(), onTap: _openDirectory),
            if (_atRoot && _shortcuts.isNotEmpty && !_needsAccess)
              _ShortcutRow(
                shortcuts: _shortcuts,
                labelOf: _shortcutLabel,
                onTap: _openDirectory,
              ),
            Expanded(child: _body(l10n)),
          ],
        ),
      ),
    );
  }

  Widget _body(FileExplorerL10n l10n) {
    if (_needsAccess) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _EmptyState(
                icon: Icons.folder_off_rounded,
                title: l10n.fileExplorerAllFilesTitle,
                subtitle: l10n.fileExplorerAllFilesBody,
              ),
              FilledButton(
                onPressed: _bootstrap,
                child: Text(l10n.fileExplorerAllFilesAction),
              ),
            ],
          ),
        ),
      );
    }
    if (_loading) {
      return const Center(child: BirdLoader(size: 72));
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, style: const TextStyle(color: kSettingsInk)),
            const SizedBox(height: 8),
            TextButton(onPressed: _load, child: Text(l10n.fileExplorerRetry)),
          ],
        ),
      );
    }
    if (_entries.isEmpty) {
      return _EmptyState(
        icon: Icons.folder_open_rounded,
        title: l10n.fileExplorerEmpty,
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: SettingsSurface(
        child: ListView.builder(
          padding: const EdgeInsets.fromLTRB(0, 10, 0, 8),
          itemCount: _entries.length,
          itemBuilder: (context, index) {
            final entry = _entries[index];
            final selected = _selected.contains(entry.path);
            return ListTile(
              minTileHeight: 60,
              leading: FileExplorerIcon(entry: entry),
              title: Text(
                entry.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  color: kSettingsInk,
                ),
              ),
              subtitle: Text(
                entry.isDirectory
                    ? fileExplorerL10n.fileExplorerFolder
                    : _formatBytes(entry.sizeBytes),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: kSettingsMutedInk, fontSize: 12),
              ),
              trailing: entry.isDirectory
                  ? const Icon(Icons.chevron_right_rounded, color: kSettingsMutedInk)
                  : widget.allowMultiple
                  ? Icon(
                      selected
                          ? Icons.check_circle_rounded
                          : Icons.circle_outlined,
                      color: selected ? AmlTheme.violet : kSettingsMutedInk,
                    )
                  : null,
              selected: selected,
              onTap: () => _pick(entry),
            );
          },
        ),
      ),
    );
  }
}

class _FileExplorerSortSheet extends StatefulWidget {
  const _FileExplorerSortSheet({
    required this.sort,
    required this.onChanged,
  });

  final FileExplorerSort sort;
  final ValueChanged<FileExplorerSort> onChanged;

  @override
  State<_FileExplorerSortSheet> createState() => _FileExplorerSortSheetState();
}

class _FileExplorerSortSheetState extends State<_FileExplorerSortSheet> {
  late FileExplorerSort _sort = widget.sort;

  void _change(FileExplorerSort next) {
    if (next == _sort) return;
    setState(() => _sort = next);
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    const l10n = fileExplorerL10n;
    return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.fileExplorerSort,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: kSettingsInk,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            l10n.fileExplorerSortBy,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: kSettingsMutedInk,
            ),
          ),
          const SizedBox(height: 8),
          SettingsChoicePicker<FileExplorerSortField>(
            choices: [
              SettingsChoice(
                value: FileExplorerSortField.date,
                label: l10n.fileExplorerSortDate,
                icon: Icons.calendar_month_rounded,
              ),
              SettingsChoice(
                value: FileExplorerSortField.name,
                label: l10n.fileExplorerSortName,
                icon: Icons.sort_by_alpha_rounded,
              ),
            ],
            selected: _sort.field,
            onSelected: (field) => _change(_sort.copyWith(field: field)),
          ),
          const SizedBox(height: 16),
          Text(
            l10n.fileExplorerSortOrder,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: kSettingsMutedInk,
            ),
          ),
          const SizedBox(height: 8),
          SettingsChoicePicker<FileExplorerSortDirection>(
            choices: [
              SettingsChoice(
                value: FileExplorerSortDirection.ascending,
                label: l10n.fileExplorerSortAscending,
                icon: Icons.arrow_upward_rounded,
              ),
              SettingsChoice(
                value: FileExplorerSortDirection.descending,
                label: l10n.fileExplorerSortDescending,
                icon: Icons.arrow_downward_rounded,
              ),
            ],
            selected: _sort.direction,
            onSelected: (direction) =>
                _change(_sort.copyWith(direction: direction)),
          ),
          const SizedBox(height: 16),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
        ],
    );
  }
}

class _Breadcrumb extends StatelessWidget {
  const _Breadcrumb({required this.crumbs, required this.onTap});

  final List<({String label, String path})> crumbs;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: SettingsSurface(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        borderRadius: 18,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          reverse: true,
          child: Row(
            children: [
              for (var i = 0; i < crumbs.length; i++) ...[
                if (i > 0)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 4),
                    child: Icon(
                      Icons.chevron_right_rounded,
                      size: 16,
                      color: kSettingsMutedInk,
                    ),
                  ),
                InkWell(
                  onTap: i == crumbs.length - 1
                      ? null
                      : () => onTap(crumbs[i].path),
                  borderRadius: BorderRadius.circular(8),
                  child: Text(
                    crumbs[i].label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: i == crumbs.length - 1
                          ? FontWeight.w700
                          : FontWeight.w600,
                      color: i == crumbs.length - 1
                          ? kSettingsInk
                          : kSettingsMutedInk,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ShortcutRow extends StatelessWidget {
  const _ShortcutRow({
    required this.shortcuts,
    required this.labelOf,
    required this.onTap,
  });

  final List<FileExplorerShortcut> shortcuts;
  final String Function(FileExplorerShortcut) labelOf;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 92,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
        scrollDirection: Axis.horizontal,
        itemCount: shortcuts.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          final shortcut = shortcuts[index];
          return Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () => onTap(shortcut.path),
              borderRadius: BorderRadius.circular(16),
              child: SizedBox(
                width: 76,
                child: Column(
                  children: [
                    FileExplorerKindIcon(
                      kind: shortcut.label == 'pictures' ||
                              shortcut.label == 'dcim'
                          ? FileExplorerKind.image
                          : shortcut.label == 'videos'
                          ? FileExplorerKind.video
                          : shortcut.label == 'music'
                          ? FileExplorerKind.audio
                          : FileExplorerKind.folder,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      labelOf(shortcut),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: kSettingsInk,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    this.subtitle,
  });

  final IconData icon;
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: kSettingsMutedInk),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 16,
                color: kSettingsInk,
              ),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 6),
              Text(
                subtitle!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                  color: kSettingsMutedInk,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _NewFolderDialog extends StatefulWidget {
  const _NewFolderDialog({required this.l10n});

  final FileExplorerL10n l10n;

  @override
  State<_NewFolderDialog> createState() => _NewFolderDialogState();
}

class _NewFolderDialogState extends State<_NewFolderDialog> {
  late final TextEditingController _name;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController();
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final clean = sanitizeFileExplorerFolderName(_name.text);
    if (clean == null) return;
    Navigator.of(context).pop(clean);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = widget.l10n;
    return AlertDialog(
      title: Text(l10n.fileExplorerNewFolder),
      content: TextField(
        controller: _name,
        autofocus: true,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _submit(),
        decoration: InputDecoration(
          hintText: l10n.fileExplorerNewFolderHint,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.fileExplorerCancel),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(l10n.fileExplorerCreate),
        ),
      ],
    );
  }
}
