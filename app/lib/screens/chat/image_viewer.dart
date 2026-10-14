import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/localizations.dart';

/// Full-screen, zoomable preview for an image attachment. Pushed as its own
/// route so it layers above the chat on a black backdrop.
class ImageViewerScreen extends StatefulWidget {
  final File file;
  final String name;
  final VoidCallback? onOpenExternally;

  const ImageViewerScreen({
    super.key,
    required this.file,
    required this.name,
    this.onOpenExternally,
  });

  @override
  State<ImageViewerScreen> createState() => _ImageViewerScreenState();
}

class _ImageViewerScreenState extends State<ImageViewerScreen> {
  final TransformationController _transform = TransformationController();

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  void _reset() {
    _transform.value = Matrix4.identity();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black.withValues(alpha: 0.8),
        foregroundColor: Colors.white,
        title: Text(
          widget.name,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 16),
        ),
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: L.t('Close', ru: 'Закрыть'),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        actions: [
          if (widget.onOpenExternally != null)
            IconButton(
              icon: const Icon(Icons.open_in_new),
              tooltip: L.t('Open externally', ru: 'Открыть в другом приложении'),
              onPressed: widget.onOpenExternally,
            ),
        ],
      ),
      body: GestureDetector(
        onDoubleTap: _reset,
        child: InteractiveViewer(
          transformationController: _transform,
          minScale: 1,
          maxScale: 6,
          child: Center(
            child: Image.file(
              widget.file,
              fit: BoxFit.contain,
              errorBuilder: (context, error, stack) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.broken_image_outlined,
                    color: Colors.white54,
                    size: 48,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    L.t('Could not display image', ru: 'Не удалось показать изображение'),
                    style: const TextStyle(color: Colors.white70),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
