import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/api.dart';
import '../models.dart';

import '../core/localizations.dart';

class AttachmentHelper {
  static Future<String?> download(String token, Attachment attachment) async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, p.basename(attachment.name)));
    if (!file.existsSync()) {
      final uri = Uri.parse(Api.attachmentUrl(attachment.url));
      final resp = await http.get(
        uri,
        headers: {'Authorization': 'Bearer $token'},
      );
      if (resp.statusCode != 200) {
        return L.t(
          'Download failed (HTTP ${resp.statusCode})',
          ru: 'Не удалось скачать (HTTP ${resp.statusCode})',
        );
      }
      await file.writeAsBytes(resp.bodyBytes);
    }
    return null;
  }

  static Future<String?> downloadAndOpen(
    String token,
    Attachment attachment,
  ) async {
    final error = await download(token, attachment);
    if (error != null) return error;
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, p.basename(attachment.name)));
    final result = await OpenFilex.open(file.path);
    if (result.type != ResultType.done &&
        result.type != ResultType.noAppToOpen) {
      return L.t(
        'Could not open file: ${result.message}',
        ru: 'Не удалось открыть файл: ${result.message}',
      );
    }
    return null;
  }
}

String formatClock(DateTime time) {
  final l = time.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(l.hour)}:${two(l.minute)}';
}

String previewOf(Message message) {
  switch (message.kind) {
    case MessageKind.text:
      return message.body;
    case MessageKind.file:
      return '📎 ${message.attachment?.name ?? message.body}';
    case MessageKind.game:
      return L.t('🎮 Minigame', ru: '🎮 Мини-игра');
  }
}
