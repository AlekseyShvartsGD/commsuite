import 'dart:io';

import 'package:commsuite/services/download_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('sanitizeFileName', () {
    test('replaces characters filesystems reject', () {
      expect(DownloadService.sanitizeFileName('a/b\\c:d*e?f"g<h>i|j'), 'a_b_c_d_e_f_g_h_i_j');
      expect(DownloadService.sanitizeFileName('  spaced.txt  '), 'spaced.txt');
    });

    test('strips path traversal and trailing dots/spaces', () {
      expect(DownloadService.sanitizeFileName('..'), '');
      // Separators become underscores and every ".." collapses, so a name can
      // never walk out of the downloads folder.
      expect(DownloadService.sanitizeFileName('../../etc/passwd'), '._._etc_passwd');
      expect(DownloadService.sanitizeFileName('name...'), 'name');
      expect(DownloadService.sanitizeFileName('name. '), 'name');
    });

    test('keeps the extension when truncating long names', () {
      final long = '${'a' * 300}.tar.gz';
      final out = DownloadService.sanitizeFileName(long);
      expect(out.length, lessThanOrEqualTo(120));
      expect(out, endsWith('.tar.gz'));
    });

    test('handles empty and control characters', () {
      expect(DownloadService.sanitizeFileName(''), '');
      expect(DownloadService.sanitizeFileName('a\u0000b\u001fc'), 'a_b_c');
    });
  });

  group('rename and delete', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('commsuite-dl-test');
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    File makeFile(String name, [String content = 'x']) {
      final f = File('${dir.path}${Platform.pathSeparator}$name')
        ..writeAsStringSync(content);
      return f;
    }

    DownloadItem itemFor(File f) => DownloadItem(
          path: f.path,
          name: f.uri.pathSegments.last,
          size: f.lengthSync(),
          addedAt: DateTime.now(),
          sourceUrl: '',
        );

    test('rename moves the file on disk', () async {
      final f = makeFile('old.txt', 'hello');
      final item = itemFor(f);
      final newName = await DownloadService.instance.rename(item, 'new.txt');
      expect(newName, 'new.txt');
      expect(File(item.path).existsSync(), isFalse);
      expect(File('${dir.path}${Platform.pathSeparator}new.txt').readAsStringSync(), 'hello');
    });

    test('rename sanitizes the new name', () async {
      final f = makeFile('a.txt');
      final name = await DownloadService.instance.rename(itemFor(f), 'we:ird?.txt');
      expect(name, 'we_ird_.txt');
    });

    test('rename refuses to overwrite an existing file', () async {
      makeFile('a.txt');
      makeFile('b.txt');
      expect(
        () => DownloadService.instance.rename(itemFor(File('${dir.path}${Platform.pathSeparator}a.txt')), 'b.txt'),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('delete removes the file', () async {
      final f = makeFile('gone.txt');
      final item = itemFor(f);
      await DownloadService.instance.delete(item);
      expect(f.existsSync(), isFalse);
      expect(DownloadService.instance.items.contains(item), isFalse);
    });

    test('delete tolerates a file that is already gone', () async {
      // The row is still removed even though nothing was on disk to unlink.
      final item = DownloadItem(
        path: '${dir.path}${Platform.pathSeparator}never-existed.txt',
        name: 'never-existed.txt',
        size: 0,
        addedAt: DateTime.now(),
        sourceUrl: '',
      );
      await DownloadService.instance.delete(item);
    });
  });
}
