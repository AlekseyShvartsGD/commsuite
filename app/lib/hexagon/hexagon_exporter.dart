import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;

import 'hexagon_generator.dart';
import 'hexagon_models.dart';

class HexExportResult {
  const HexExportResult({required this.path, required this.isFolder});

  final String path;
  final bool isFolder;
}

class HexPackExporter {
  HexPackExporter._();

  /// Builds the complete pack archive, including the bundled silent track.
  static Future<Uint8List> buildZip(HexMapDraft draft) async {
    final pack = HexPackBuilder.build(draft);
    final archive = Archive();

    for (final entry in pack.textFiles.entries) {
      archive.add(
        ArchiveFile.string('${pack.packFolder}/${entry.key}', entry.value),
      );
    }
    for (final entry in pack.audioFiles.entries) {
      final data = await rootBundle.load(entry.value);
      archive.add(
        ArchiveFile.bytes(
          '${pack.packFolder}/${entry.key}',
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        ),
      );
    }

    return ZipEncoder().encodeBytes(archive);
  }

  /// Opens a save dialog and writes `<pack>.zip` to the chosen location.
  /// Returns null when the user cancels.
  static Future<HexExportResult?> exportZip(HexMapDraft draft) async {
    final bytes = await buildZip(draft);
    final uri = await FilePicker.saveFile(
      dialogTitle: 'Save Open Hexagon pack',
      fileName: '${draft.packSlug}.zip',
      bytes: bytes,
      mimeType: 'application/zip',
      type: FileType.custom,
      allowedExtensions: const ['zip'],
    );
    if (uri == null) return null;
    return HexExportResult(path: uri.toString(), isFolder: false);
  }

  /// Writes the unpacked pack into `<chosen folder>/<pack folder>/`, ready to
  /// drop straight into Open Hexagon's `Packs` directory. Returns null when
  /// the user cancels.
  static Future<HexExportResult?> exportFolder(HexMapDraft draft) async {
    final parent = await FilePicker.getDirectoryPath(
      dialogTitle: 'Choose a folder for the pack (or your Packs folder)',
    );
    if (parent == null) return null;

    final pack = HexPackBuilder.build(draft);
    final root = Directory(p.join(parent, pack.packFolder));
    if (await root.exists()) {
      // Re-exporting should update a pack, not silently mix old files in.
      await root.delete(recursive: true);
    }
    await root.create(recursive: true);

    for (final entry in pack.textFiles.entries) {
      final file = File(p.join(root.path, entry.key));
      await file.parent.create(recursive: true);
      await file.writeAsString(entry.value, encoding: utf8);
    }
    for (final entry in pack.audioFiles.entries) {
      final data = await rootBundle.load(entry.value);
      final file = File(p.join(root.path, entry.key));
      await file.parent.create(recursive: true);
      await file.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
    }

    return HexExportResult(path: root.path, isFolder: true);
  }
}
