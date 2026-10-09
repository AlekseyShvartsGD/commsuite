import 'dart:io';

import 'package:path/path.dart' as p;

class FileEntry {
  final String path;
  final String name;
  final bool isDir;
  final int size;
  final DateTime modified;

  const FileEntry({
    required this.path,
    required this.name,
    required this.isDir,
    required this.size,
    required this.modified,
  });
}

class FileService {
  static Future<List<String>> roots() async {
    if (Platform.isAndroid) {
      final candidates = ['/storage/emulated/0', '/storage', '/sdcard'];
      return candidates.where((c) => Directory(c).existsSync()).toList();
    }
    if (Platform.isWindows) {
      final drives = <String>[];
      for (var c = 'A'.codeUnitAt(0); c <= 'Z'.codeUnitAt(0); c++) {
        final letter = String.fromCharCode(c);
        final path = '$letter:\\';
        try {
          if (Directory(path).existsSync()) drives.add(path);
        } catch (_) {}
      }
      return drives;
    }
    final home = Platform.environment['HOME'];
    if (home != null && Directory(home).existsSync()) return [home];
    return [Directory.current.path];
  }

  static Future<List<FileEntry>> list(String dirPath) async {
    try {
      final entities = await Directory(dirPath)
          .list(followLinks: false)
          .toList();
      final entries = <FileEntry>[];
      for (final e in entities) {
        try {
          final st = e.statSync();
          entries.add(
            FileEntry(
              path: e.path,
              name: p.basename(e.path),
              isDir: st.type == FileSystemEntityType.directory,
              size: st.size,
              modified: st.modified,
            ),
          );
        } catch (_) {}
      }
      entries.sort((a, b) {
        if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      return entries;
    } catch (_) {
      return [];
    }
  }

  static String formatSize(num bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  static String formatDate(DateTime d) {
    final l = d.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
  }
}
