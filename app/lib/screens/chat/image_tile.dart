import 'dart:io';

import 'package:flutter/material.dart';

import '../../app.dart';
import '../../models.dart';
import '../../services/attachment_helper.dart';
import '../../services/file_service.dart';
import '../../core/localizations.dart';
import 'image_viewer.dart';

class ImageAttachmentTile extends StatelessWidget {
  final Message message;

  const ImageAttachmentTile({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    final attachment = message.attachment;
    if (attachment == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () async {
        final token = CommsScope.read(context).token;
        if (token == null) return;
        final file = await AttachmentHelper.localFile(attachment);
        if (!file.existsSync()) {
          final error = await AttachmentHelper.download(token, attachment);
          if (error != null && context.mounted) {
            CommsScope.read(context).showSnack(error);
            return;
          }
        }
        if (!context.mounted) return;
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => ImageViewerScreen(
              file: file,
              name: attachment.name,
              onOpenExternally: () async {
                final err = await AttachmentHelper.downloadAndOpen(
                  token,
                  attachment,
                );
                if (err != null && context.mounted) {
                  CommsScope.read(context).showSnack(err);
                }
              },
            ),
          ),
        );
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: FutureBuilder<File>(
              future: AttachmentHelper.localFile(attachment),
              builder: (context, snapshot) {
                final file = snapshot.data;
                if (file != null && file.existsSync()) {
                  return ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 280, maxHeight: 320),
                    child: Image.file(
                      file,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => Container(
                        height: 160,
                        color: scheme.surfaceContainerHighest,
                        child: const Icon(Icons.broken_image_outlined),
                      ),
                    ),
                  );
                }
                return Container(
                  width: 240,
                  height: 160,
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.image_outlined),
                      const SizedBox(height: 6),
                      Text(
                        L.t('Tap to load preview', ru: 'Нажмите, чтобы загрузить'),
                        style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                      ),
                      Text(
                        FileService.formatSize(attachment.size),
                        style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          if (attachment.name.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 2),
              child: Text(
                attachment.name,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );
  }
}
