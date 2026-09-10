import 'dart:io';

class FlutterL10nRunner {
  static void run(String workingDirectory) {
    print('Running flutter gen-l10n...');
    final genResult = Process.runSync('flutter', [
      'gen-l10n',
    ], workingDirectory: workingDirectory);
    if (genResult.exitCode != 0) {
      stderr.writeln('flutter gen-l10n failed:\n${genResult.stderr}');
    } else {
      final out = (genResult.stdout as String).trim();
      if (out.isNotEmpty) {
        print(out);
      }
      print('  ✓ flutter gen-l10n complete.');
    }
  }
}
