import 'dart:io';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:permission_handler/permission_handler.dart' as ph;

import '../../services/file_service.dart';
import '../../core/localizations.dart';

class FilesScreen extends StatefulWidget {
  const FilesScreen({super.key});

  @override
  State<FilesScreen> createState() => _FilesScreenState();
}

enum _ClipboardAction { copy, cut }

class _FilesScreenState extends State<FilesScreen> {
  String? _currentPath;
  List<FileEntry>? _entries;
  String _filter = '';
  bool _searching = false;
  String? _clipboardPath;
  _ClipboardAction? _clipboardAction;
  bool _loading = true;
  String? _permissionWarn;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    if (Platform.isAndroid) {
      final status = await ph.Permission.storage.request();
      if (!status.isGranted) {
        setState(
          () => _permissionWarn = L.t(
            'File access not granted (${status.isPermanentlyDenied ? 'open Settings → Apps → Commsuite and allow storage' : 'allow storage when prompted'}).',
            ru: 'Доступ к файлам не предоставлен (${status.isPermanentlyDenied ? 'откройте Настройки → Приложения → Commsuite и разрешите доступ к хранилищу' : 'разрешите доступ к хранилищу в запросе'}).',
          ),
        );
      }
    }
    final roots = await FileService.roots();
    if (roots.isEmpty) {
      setState(() => _loading = false);
      return;
    }
    await _go(roots.first);
  }

  Future<void> _go(String path) async {
    setState(() => _loading = true);
    final entries = await FileService.list(path);
    if (!mounted) return;
    setState(() {
      _currentPath = path;
      _entries = entries;
      _loading = false;
      _filter = '';
    });
  }

  Future<void> _up() async {
    if (_currentPath == null) return;
    final dir = Directory(_currentPath!).parent.path;
    if (dir == _currentPath) return;
    setState(() => _loading = true);
    final entries = await FileService.list(dir);
    if (!mounted) return;
    setState(() {
      _currentPath = dir;
      _entries = entries;
      _loading = false;
    });
  }

  Future<void> _refresh() async {
    if (_currentPath == null) return;
    final entries = await FileService.list(_currentPath!);
    if (!mounted) return;
    setState(() => _entries = entries);
  }

  Future<void> _openEntry(FileEntry e) async {
    if (e.isDir) {
      await _go(e.path);
      return;
    }
    final result = await OpenFilex.open(e.path);
    if (result.type != ResultType.done && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            L.t(
              'Could not open: ${result.message}',
              ru: 'Не удалось открыть: ${result.message}',
            ),
          ),
        ),
      );
    }
  }

  Future<void> _newFolder() async {
    final name = await _promptText(
      L.t('New folder', ru: 'Новая папка'),
      L.t('Folder name', ru: 'Имя папки'),
    );
    if (name == null || name.isEmpty || _currentPath == null) return;
    try {
      await Directory('$_currentPath${Platform.pathSeparator}$name').create();
      await _refresh();
    } catch (e) {
      _error(
        L.t('Could not create folder: $e', ru: 'Не удалось создать папку: $e'),
      );
    }
  }

  Future<void> _rename(FileEntry e) async {
    final name = await _promptText(
      L.t('Rename', ru: 'Переименовать'),
      L.t('New name', ru: 'Новое имя'),
      initial: e.name,
    );
    if (name == null || name.isEmpty || name == e.name) return;
    try {
      final newPath =
          '${Directory(e.path).parent.path}${Platform.pathSeparator}$name';
      try {
        await File(e.path).rename(newPath);
      } catch (_) {
        await Directory(e.path).rename(newPath);
      }
      await _refresh();
    } catch (e) {
      _error(L.t('Could not rename: $e', ru: 'Не удалось переименовать: $e'));
    }
  }

  Future<void> _delete(FileEntry e) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(L.t('Delete ${e.name}?', ru: 'Удалить ${e.name}?')),
        content: Text(
          e.isDir
              ? L.t(
                  'The folder and its contents will be deleted.',
                  ru: 'Папка и её содержимое будут удалены.',
                )
              : L.t(
                  'This cannot be undone.',
                  ru: 'Это действие нельзя отменить.',
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(L.t('Cancel', ru: 'Отмена')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(L.t('Delete', ru: 'Удалить')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      if (e.isDir) {
        await Directory(e.path).delete(recursive: true);
      } else {
        await File(e.path).delete();
      }
      await _refresh();
    } catch (err) {
      _error(L.t('Could not delete: $err', ru: 'Не удалось удалить: $err'));
    }
  }

  void _clip(FileEntry e, _ClipboardAction action) {
    setState(() {
      _clipboardPath = e.path;
      _clipboardAction = action;
    });
  }

  Future<void> _paste() async {
    final src = _clipboardPath;
    final action = _clipboardAction;
    final dest = _currentPath;
    if (src == null || action == null || dest == null) return;
    final name = src.split(Platform.pathSeparator).last;
    final target = '$dest${Platform.pathSeparator}$name';
    try {
      if (action == _ClipboardAction.cut) {
        try {
          await Directory(src).rename(target);
        } catch (_) {
          await File(src).rename(target);
        }
      } else {
        await _copyRecursive(src, target);
      }
      await _refresh();
    } catch (e) {
      _error(L.t('Could not paste: $e', ru: 'Не удалось вставить: $e'));
    }
  }

  Future<void> _copyRecursive(String src, String dest) async {
    final source = Directory(src);
    if (!source.existsSync()) {
      await File(src).copy(dest);
      return;
    }
    await Directory(dest).create(recursive: true);
    await for (final entity in source.list(followLinks: false)) {
      if (entity is Directory) {
        await _copyRecursive(
          entity.path,
          '$dest${Platform.pathSeparator}${entity.path.split(Platform.pathSeparator).last}',
        );
      } else {
        await File(entity.path).copy(
          '$dest${Platform.pathSeparator}${entity.path.split(Platform.pathSeparator).last}',
        );
      }
    }
  }

  Future<void> _showInfo(FileEntry e) async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(e.name),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              e.isDir
                  ? L.t('Type: Folder', ru: 'Тип: Папка')
                  : L.t('Type: File', ru: 'Тип: Файл'),
            ),
            Text(L.t('Path: ${e.path}', ru: 'Путь: ${e.path}')),
            if (!e.isDir)
              Text(
                L.t(
                  'Size: ${FileService.formatSize(e.size)}',
                  ru: 'Размер: ${FileService.formatSize(e.size)}',
                ),
              ),
            Text(
              L.t(
                'Modified: ${FileService.formatDate(e.modified)}',
                ru: 'Изменено: ${FileService.formatDate(e.modified)}',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(L.t('Close', ru: 'Закрыть')),
          ),
        ],
      ),
    );
  }

  Future<String?> _promptText(
    String title,
    String label, {
    String? initial,
  }) async {
    final controller = TextEditingController(text: initial ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(labelText: label),
          onSubmitted: (v) => Navigator.of(context).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(L.t('Cancel', ru: 'Отмена')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: Text(L.t('OK', ru: 'ОК')),
          ),
        ],
      ),
    );
    return result;
  }

  void _error(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  void _showActions(FileEntry e) {
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(e.isDir ? Icons.folder : _iconFor(e.name)),
              title: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                e.isDir
                    ? L.t('Folder', ru: 'Папка')
                    : '${FileService.formatSize(e.size)} · ${FileService.formatDate(e.modified)}',
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.open_in_new),
              title: Text(
                e.isDir
                    ? L.t('Open folder', ru: 'Открыть папку')
                    : L.t('Open', ru: 'Открыть'),
              ),
              onTap: () {
                Navigator.of(context).pop();
                _openEntry(e);
              },
            ),
            ListTile(
              leading: const Icon(Icons.edit),
              title: Text(L.t('Rename', ru: 'Переименовать')),
              onTap: () {
                Navigator.of(context).pop();
                _rename(e);
              },
            ),
            ListTile(
              leading: const Icon(Icons.content_copy),
              title: Text(L.t('Copy', ru: 'Копировать')),
              onTap: () {
                Navigator.of(context).pop();
                _clip(e, _ClipboardAction.copy);
              },
            ),
            ListTile(
              leading: const Icon(Icons.content_cut),
              title: Text(L.t('Cut', ru: 'Вырезать')),
              onTap: () {
                Navigator.of(context).pop();
                _clip(e, _ClipboardAction.cut);
              },
            ),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: Text(L.t('Properties', ru: 'Свойства')),
              onTap: () {
                Navigator.of(context).pop();
                _showInfo(e);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: Text(
                L.t('Delete', ru: 'Удалить'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              onTap: () {
                Navigator.of(context).pop();
                _delete(e);
              },
            ),
          ],
        ),
      ),
    );
  }

  IconData _iconFor(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    if (['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp'].contains(ext)) {
      return Icons.image_outlined;
    }
    if (['mp3', 'wav', 'flac', 'm4a', 'ogg'].contains(ext)) {
      return Icons.audiotrack;
    }
    if (['mp4', 'mkv', 'avi', 'mov', 'webm'].contains(ext)) {
      return Icons.movie_outlined;
    }
    if (['pdf'].contains(ext)) return Icons.picture_as_pdf_outlined;
    if (['zip', 'rar', '7z', 'tar', 'gz'].contains(ext)) {
      return Icons.folder_zip_outlined;
    }
    if (['doc', 'docx', 'odt'].contains(ext)) return Icons.description_outlined;
    if (['xls', 'xlsx', 'csv', 'ods'].contains(ext)) {
      return Icons.table_chart_outlined;
    }
    if (['ppt', 'pptx'].contains(ext)) return Icons.slideshow_outlined;
    if ([
      'txt',
      'md',
      'json',
      'js',
      'ts',
      'py',
      'dart',
      'html',
      'css',
    ].contains(ext)) {
      return Icons.text_snippet_outlined;
    }
    return Icons.insert_drive_file_outlined;
  }

  String get _currentLabel {
    final path = _currentPath;
    if (path == null) return L.t('Files', ru: 'Файлы');
    if (path == '/' || path.length <= 4) return path;
    return path.split(Platform.pathSeparator).last;
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries ?? const <FileEntry>[];
    final filtered = _filter.isEmpty
        ? entries
        : entries
              .where(
                (e) => e.name.toLowerCase().contains(_filter.toLowerCase()),
              )
              .toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(_currentLabel),
        actions: [
          if (_clipboardPath != null && _clipboardAction != null)
            TextButton.icon(
              onPressed: _paste,
              icon: Icon(
                _clipboardAction == _ClipboardAction.cut
                    ? Icons.content_cut
                    : Icons.content_copy,
              ),
              label: Text(L.t('Paste', ru: 'Вставить')),
            ),
          if (_searching)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: IconButton(
                icon: const Icon(Icons.close),
                tooltip: L.t('Exit search', ru: 'Выйти из поиска'),
                onPressed: () => setState(() {
                  _searching = false;
                  _filter = '';
                }),
              ),
            )
          else ...[
            IconButton(
              icon: const Icon(Icons.search),
              tooltip: L.t('Search', ru: 'Поиск'),
              onPressed: () => setState(() => _searching = true),
            ),
            IconButton(
              icon: const Icon(Icons.create_new_folder_outlined),
              tooltip: L.t('New folder', ru: 'Новая папка'),
              onPressed: _newFolder,
            ),
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: L.t('Refresh', ru: 'Обновить'),
              onPressed: _refresh,
            ),
          ],
        ],
      ),
      body: _permissionWarn != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.folder_off,
                      size: 56,
                      color: Theme.of(context).colorScheme.error,
                    ),
                    const SizedBox(height: 12),
                    Text(_permissionWarn!, textAlign: TextAlign.center),
                  ],
                ),
              ),
            )
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_upward),
                        tooltip: L.t('Go up', ru: 'Вверх'),
                        onPressed: _up,
                      ),
                      Expanded(
                        child: Text(
                          _currentPath ?? '',
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ),
                if (_searching)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: TextField(
                      autofocus: true,
                      decoration: InputDecoration(
                        hintText: L.t(
                          'Filter files in this folder…',
                          ru: 'Фильтр файлов в этой папке…',
                        ),
                        prefixIcon: const Icon(Icons.search),
                      ),
                      onChanged: (v) => setState(() => _filter = v),
                    ),
                  ),
                const Divider(height: 1),
                Expanded(
                  child: _loading
                      ? const Center(child: CircularProgressIndicator())
                      : filtered.isEmpty
                      ? Center(
                          child: Text(
                            L.t('This folder is empty', ru: 'Эта папка пуста'),
                          ),
                        )
                      : ListView.builder(
                          itemCount: filtered.length,
                          itemBuilder: (context, index) {
                            final e = filtered[index];
                            return ListTile(
                              leading: Icon(
                                e.isDir ? Icons.folder : _iconFor(e.name),
                                color: e.isDir
                                    ? Theme.of(context).colorScheme.primary
                                    : null,
                              ),
                              title: Text(
                                e.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                e.isDir
                                    ? L.t('Folder', ru: 'Папка')
                                    : '${FileService.formatSize(e.size)} · ${FileService.formatDate(e.modified)}',
                              ),
                              onTap: () => _openEntry(e),
                              onLongPress: () => _showActions(e),
                              trailing: e.isDir
                                  ? null
                                  : IconButton(
                                      icon: const Icon(Icons.more_vert),
                                      onPressed: () => _showActions(e),
                                    ),
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }
}
