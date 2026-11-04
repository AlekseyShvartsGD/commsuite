import 'package:flutter_test/flutter_test.dart';

import 'package:commsuite/services/crash_reporter.dart';

void main() {
  group('CrashReporter fingerprinting', () {
    test('ignores the log timestamp', () {
      const first = '[2026-11-03T10:00:00.000Z]\n'
          'Bad state: boom\n#0      main (package:commsuite/main.dart:10:3)';
      const second = '[2026-11-04T11:30:00.000Z]\n'
          'Bad state: boom\n#0      main (package:commsuite/main.dart:10:3)';

      expect(CrashReporter.fingerprint(first),
          CrashReporter.fingerprint(second));
    });

    test('includes the first stack frame so distinct sites differ', () {
      const one = '[2026-11-03T10:00:00.000Z]\n'
          'Bad state: boom\n#0      first (package:commsuite/a.dart:1:1)';
      const two = '[2026-11-03T10:00:00.000Z]\n'
          'Bad state: boom\n#0      second (package:commsuite/b.dart:2:2)';

      expect(CrashReporter.fingerprint(one),
          isNot(CrashReporter.fingerprint(two)));
    });

    test('remembers reports for the session without growing forever', () {
      final report = '[2026-11-03T10:00:00.000Z]\n'
          'Unique report ${DateTime.now().microsecondsSinceEpoch}\n'
          '#0      main (package:commsuite/main.dart:10:3)';

      expect(CrashReporter.wasReported(report), isFalse);
      CrashReporter.markReported(report);
      expect(CrashReporter.wasReported(report), isTrue);
    });
  });
}
