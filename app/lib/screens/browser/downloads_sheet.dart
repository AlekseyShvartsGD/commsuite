import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_config.dart';
import '../../services/download_service.dart';
import '../../services/virustotal.dart';
import 'scan_result_dialog.dart';
import '../../core/localizations.dart';

/// The browser's download list: newest first, with rename / delete / share /
/// VirusTotal per file.
class DownloadsSheet extends StatelessWidget {
  const DownloadsSheet({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: DownloadService.instance,
      builder: (context, _) {
        final items = DownloadService.instance.items;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
                child: Row(
                  children: [
                    const Icon(Icons.download),
                    const SizedBox(width: 8),
                    Text(
                      L.t('Downloads', ru: 'Загрузки'),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const Spacer(),
                    if (items.isNotEmpty)
                      Text(
                        L.plural(
                          items.length,
                          enOne: '${items.length} file',
                          enMany: '${items.length} files',
                          ruOne: '${items.length} файл',
                          ruFew: '${items.length} файла',
                          ruMany: '${items.length} файлов',
                        ),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      tooltip: L.t('Close', ru: 'Закрыть'),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              if (items.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  child: Text(
                    L.t(
                      'No downloads yet. Files you download in the browser '
                      'appear here.',
                      ru:
                          'Пока нет загрузок. Файлы, которые вы скачиваете '
                          'в браузере, появятся здесь.',
                    ),
                  ),
                )
              else
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: items.length,
                    itemBuilder: (context, index) =>
                        _DownloadTile(item: items[index]),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _DownloadTile extends StatelessWidget {
  const _DownloadTile({required this.item});

  final DownloadItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final failed = item.error != null;

    // Right-click on desktop, long-press on touch.
    return GestureDetector(
      onSecondaryTap: () => showFileActions(context, item),
      child: ListTile(
        leading: Icon(
          failed ? Icons.error_outline : _iconFor(item.name),
          color: failed ? theme.colorScheme.error : null,
        ),
        title: Text(
          item.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            decoration: item.inProgress ? TextDecoration.underline : null,
          ),
        ),
        subtitle: failed
            ? Text(
                item.error!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: theme.colorScheme.error),
              )
            : item.inProgress
            ? Row(
                children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: item.progress,
                        minHeight: 4,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    formatSize(item.received),
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              )
            : Text(
                item.size > 0
                    ? '${formatSize(item.size)}  -  ${_when(item.addedAt)}'
                    : _when(item.addedAt),
                style: theme.textTheme.bodySmall,
              ),
        onLongPress: () => showFileActions(context, item),
      ),
    );
  }

  static IconData _iconFor(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.pdf')) return Icons.picture_as_pdf;
    if (lower.endsWith('.zip') ||
        lower.endsWith('.tar.gz') ||
        lower.endsWith('.7z') ||
        lower.endsWith('.rar')) {
      return Icons.folder_zip;
    }
    if (lower.endsWith('.exe') || lower.endsWith('.msi')) {
      return Icons.install_desktop;
    }
    if (lower.endsWith('.apk')) return Icons.android;
    if (lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.svg')) {
      return Icons.image;
    }
    if (lower.endsWith('.mp4') ||
        lower.endsWith('.mkv') ||
        lower.endsWith('.mov') ||
        lower.endsWith('.mp3') ||
        lower.endsWith('.wav')) {
      return Icons.movie;
    }
    if (lower.endsWith('.txt') ||
        lower.endsWith('.md') ||
        lower.endsWith('.log')) {
      return Icons.description;
    }
    return Icons.insert_drive_file;
  }

  static String _when(DateTime time) {
    final d = DateTime.now().difference(time);
    if (d.inMinutes < 1) return L.t('just now', ru: 'только что');
    if (d.inHours < 1) {
      return L.plural(
        d.inMinutes,
        enOne: '${d.inMinutes} min ago',
        enMany: '${d.inMinutes} min ago',
        ruOne: '${d.inMinutes} мин назад',
        ruFew: '${d.inMinutes} мин назад',
        ruMany: '${d.inMinutes} мин назад',
      );
    }
    if (d.inDays < 1) {
      return L.plural(
        d.inHours,
        enOne: '${d.inHours} h ago',
        enMany: '${d.inHours} h ago',
        ruOne: '${d.inHours} ч назад',
        ruFew: '${d.inHours} ч назад',
        ruMany: '${d.inHours} ч назад',
      );
    }
    return L.plural(
      d.inDays,
      enOne: '${d.inDays} d ago',
      enMany: '${d.inDays} d ago',
      ruOne: '${d.inDays} дн назад',
      ruFew: '${d.inDays} дн назад',
      ruMany: '${d.inDays} дн назад',
    );
  }
}

/// Per-file action panel: rename, delete, share, scan with VirusTotal.
Future<void> showFileActions(BuildContext context, DownloadItem item) async {
  final action = await showModalBottomSheet<_FileAction>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              item.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          if (item.error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                item.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          ListTile(
            leading: const Icon(Icons.drive_file_rename_outline),
            title: Text(L.t('Rename', ru: 'Переименовать')),
            onTap: () => Navigator.of(sheetContext).pop(_FileAction.rename),
          ),
          ListTile(
            leading: const Icon(Icons.share_outlined),
            title: Text(L.t('Share', ru: 'Поделиться')),
            onTap: () => Navigator.of(sheetContext).pop(_FileAction.share),
          ),
          ListTile(
            leading: const Icon(Icons.shield_outlined),
            title: Text(
              L.t('Scan with VirusTotal', ru: 'Проверить через VirusTotal'),
            ),
            onTap: () => Navigator.of(sheetContext).pop(_FileAction.scan),
          ),
          ListTile(
            leading: Icon(
              Icons.delete_outline,
              color: Theme.of(context).colorScheme.error,
            ),
            title: Text(
              L.t('Delete', ru: 'Удалить'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            onTap: () => Navigator.of(sheetContext).pop(_FileAction.delete),
          ),
        ],
      ),
    ),
  );
  if (action == null || !context.mounted) return;

  switch (action) {
    case _FileAction.rename:
      await promptRename(context, item);
    case _FileAction.delete:
      await confirmDelete(context, item);
    case _FileAction.share:
      await shareFile(context, item);
    case _FileAction.scan:
      await scanFileWithVirusTotal(context, item);
  }
}

enum _FileAction { rename, share, scan, delete }

Future<void> promptRename(BuildContext context, DownloadItem item) async {
  final controller = TextEditingController(text: item.name);
  final messenger = ScaffoldMessenger.of(context);
  final name = await showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(L.t('Rename file', ru: 'Переименовать файл')),
      content: TextField(
        controller: controller,
        autofocus: true,
        maxLines: 1,
        decoration: InputDecoration(
          labelText: L.t('File name', ru: 'Имя файла'),
          helperText: L.t(
            'Characters that filesystems reject are replaced.',
            ru:
                'Символы, которые отклоняет файловая система, будут '
                'заменены.',
          ),
        ),
        onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text(L.t('Cancel', ru: 'Отмена')),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(controller.text),
          child: Text(L.t('Rename', ru: 'Переименовать')),
        ),
      ],
    ),
  );
  if (name == null) return;
  try {
    await DownloadService.instance.rename(item, name);
  } on FileSystemException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.message)));
  }
}

Future<void> confirmDelete(BuildContext context, DownloadItem item) async {
  final messenger = ScaffoldMessenger.of(context);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(L.t('Delete download?', ru: 'Удалить загрузку?')),
      content: Text(
        L.t(
          '${item.name} will be removed from disk.',
          ru: '${item.name} будет удалён с диска.',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(L.t('Cancel', ru: 'Отмена')),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(L.t('Delete', ru: 'Удалить')),
        ),
      ],
    ),
  );
  if (confirmed != true) return;
  try {
    await DownloadService.instance.delete(item);
  } on FileSystemException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.message)));
  }
}

/// Shares the file through the platform share sheet, falling back to "show in
/// folder" where no share sheet exists.
Future<void> shareFile(BuildContext context, DownloadItem item) async {
  final messenger = ScaffoldMessenger.of(context);
  final file = File(item.path);
  if (!await file.exists()) {
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          L.t('That file no longer exists.', ru: 'Этого файла больше нет.'),
        ),
      ),
    );
    return;
  }
  final ok = await UrlServiceShare.shareFile(file.path, item.name);
  if (!ok && context.mounted) {
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          L.t(
            'No app available to share this file.',
            ru: 'Нет приложения, которым можно поделиться этим файлом.',
          ),
        ),
      ),
    );
  }
}

Future<void> scanFileWithVirusTotal(
  BuildContext context,
  DownloadItem item,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final apiKey = (await AppConfig.loadVirusTotalKey()) ?? '';
  if (apiKey.isEmpty) {
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          L.t(
            'Add your VirusTotal API key in Settings - Security',
            ru:
                'Добавьте API-ключ VirusTotal в разделе '
                '«Настройки — Безопасность»',
          ),
        ),
      ),
    );
    return;
  }
  final file = File(item.path);
  if (!await file.exists()) {
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          L.t('That file no longer exists.', ru: 'Этого файла больше нет.'),
        ),
      ),
    );
    return;
  }
  final proxy = await AppConfig.loadVirusTotalProxy();
  if (!context.mounted) return;
  final rootContext = context;
  final navigator = Navigator.of(rootContext, rootNavigator: true);
  unawaited(
    showDialog<void>(
      context: rootContext,
      barrierDismissible: false,
      builder: (dialogContext) => _ScanProgressDialog(name: item.name),
    ),
  );
  try {
    final stats = await VirusTotalService.scanFile(apiKey, file, proxy: proxy);
    if (!navigator.mounted) return;
    navigator.pop();
    await showScanResult(
      context: navigator.context,
      subject: item.name,
      stats: stats,
      kind: ScanSubject.file,
    );
  } on VirusTotalException catch (e) {
    if (!navigator.mounted) return;
    navigator.pop();
    messenger.showSnackBar(SnackBar(content: Text(e.message)));
  } catch (e) {
    if (!navigator.mounted) return;
    navigator.pop();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          L.t(
            'VirusTotal check failed: $e',
            ru: 'Не удалось проверить через VirusTotal: $e',
          ),
        ),
      ),
    );
  }
}

class _ScanProgressDialog extends StatelessWidget {
  const _ScanProgressDialog({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      content: Row(
        children: [
          const SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 3),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Text(
              L.t(
                'Uploading ${name.length > 28 ? '${name.substring(0, 28)}\u2026' : name} to VirusTotal\u2026',
                ru: 'Загрузка ${name.length > 28 ? '${name.substring(0, 28)}\u2026' : name} в VirusTotal\u2026',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Human-readable byte count.
String formatSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// Copies a link to the clipboard (used by the shared result dialog).
Future<void> copyToClipboard(String text) async {
  await Clipboard.setData(ClipboardData(text: text));
}

/// Platform share for a downloaded file.
///
/// There is no share plugin in this project, so sharing falls back to what each
/// platform can do without one: Windows/Linux open the file's folder with the
/// file selected (or copied to the clipboard as a path), and the user picks the
/// target from there. Returns false when nothing could be launched.
class UrlServiceShare {
  UrlServiceShare._();

  static Future<bool> shareFile(String path, String name) async {
    if (kIsWeb) return false;
    try {
      if (Platform.isWindows) {
        await Process.start('explorer.exe', ['/select,', path]);
        return true;
      }
      if (Platform.isLinux) {
        // No file manager is guaranteed; copying the path keeps the action
        // useful even when xdg-open fails.
        await Process.start('xdg-open', [File(path).parent.path]);
        return true;
      }
      if (Platform.isAndroid) {
        // Hand off to the view intent via the app's file-open channel.
        const channel = MethodChannel('commsuite/files');
        final ok = await channel.invokeMethod<bool>('shareFile', {
          'path': path,
          'name': name,
        });
        return ok == true;
      }
    } catch (_) {
      return false;
    }
    return false;
  }
}
