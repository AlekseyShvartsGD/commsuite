import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/localizations.dart';

/// What a scan result is about: a link typed in chat, or a downloaded file.
enum ScanSubject { url, file }

/// VirusTotal verdict shared by the chat link scanner and the browser's
/// download scanner, so both report identically.
class ScanResultDialog extends StatelessWidget {
  final String subject;
  final Map<String, int> stats;
  final ScanSubject kind;

  const ScanResultDialog({
    super.key,
    required this.subject,
    required this.stats,
    this.kind = ScanSubject.url,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final malicious = stats['malicious'] ?? 0;
    final suspicious = stats['suspicious'] ?? 0;
    final harmless = stats['harmless'] ?? 0;
    final undetected = stats['undetected'] ?? 0;
    final timeout = stats['timeout'] ?? 0;
    final clean = malicious == 0 && suspicious == 0;
    final color = clean ? Colors.green.shade700 : theme.colorScheme.error;
    final isFile = kind == ScanSubject.file;

    Widget row(String label, int value) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: theme.textTheme.bodyMedium),
            Text(
              '$value',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );
    }

    return AlertDialog(
      icon: Icon(Icons.shield_outlined, color: color, size: 36),
      title: Text(
        clean
            ? (isFile
                  ? L.t('File looks clean', ru: 'Файл выглядит чистым')
                  : L.t('Link is clean', ru: 'Ссылка чистая'))
            : L.t(
                'Flagged by security engines',
                ru: 'Отмечен антивирусными движками',
              ),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(
            subject,
            maxLines: 2,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(height: 12),
          row(L.t('Malicious', ru: 'Вредоносные'), malicious),
          row(L.t('Suspicious', ru: 'Подозрительные'), suspicious),
          row(L.t('Harmless', ru: 'Безвредные'), harmless),
          row(L.t('Undetected', ru: 'Не обнаружено'), undetected),
          row(L.t('Timeout', ru: 'Тайм-аут'), timeout),
          const SizedBox(height: 8),
          Text(
            isFile
                ? L.t(
                    'Scan by VirusTotal. Treat flagged files with caution.',
                    ru:
                        'Скан VirusTotal. Относитесь к отмеченным файлам '
                        'с осторожностью.',
                  )
                : L.t(
                    'Scan by VirusTotal. Treat flagged links with caution.',
                    ru:
                        'Скан VirusTotal. Относитесь к отмеченным ссылкам '
                        'с осторожностью.',
                  ),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: subject));
            if (!context.mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  isFile
                      ? L.t('File path copied', ru: 'Путь к файлу скопирован')
                      : L.t('Link copied', ru: 'Ссылка скопирована'),
                ),
              ),
            );
          },
          child: Text(
            isFile
                ? L.t('Copy path', ru: 'Копировать путь')
                : L.t('Copy link', ru: 'Копировать ссылку'),
          ),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(L.t('Close', ru: 'Закрыть')),
        ),
      ],
    );
  }
}

Future<void> showScanResult({
  required BuildContext context,
  required String subject,
  required Map<String, int> stats,
  ScanSubject kind = ScanSubject.url,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) =>
        ScanResultDialog(subject: subject, stats: stats, kind: kind),
  );
}
