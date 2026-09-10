import 'dart:io';
import 'package:yaml/yaml.dart';
import 'config.dart';
import 'models.dart';
import 'yaml_strings_parser.dart';

class GitService {
  final LlmTranslateConfig config;
  final String gitRoot;
  final String cwd;

  GitService({required this.config, required this.gitRoot, required this.cwd});

  factory GitService.fromCwd(LlmTranslateConfig config, String cwd) {
    final gitRoot = runGit(['rev-parse', '--show-toplevel'], cwd);
    return GitService(config: config, gitRoot: gitRoot, cwd: cwd);
  }

  Set<String> gitDiffedKeys(KeyMap allKeys) {
    final gitRel = config.entryFile.substring(gitRoot.length + 1);
    final oldContent = gitShowOld(gitRel);
    if (oldContent == null) {
      print('No previous version in git. Translating all keys.');
      return allKeys.keys.toSet();
    }

    YamlMap? oldYaml;
    try {
      oldYaml = loadYaml(oldContent) as YamlMap?;
    } catch (e) {
      stderr.writeln(
        'Warning: could not parse git HEAD version of ${config.entryFile}, falling back to full translate.',
      );
      return allKeys.keys.toSet();
    }

    if (oldYaml == null) return allKeys.keys.toSet();

    final oldRaw = YamlStringsParser.flattenYaml(oldYaml);
    final oldMap = <String, String>{};
    for (final entry in oldRaw.entries) {
      final parsed = YamlStringsParser.parseKey(
        entry.value,
        config.paramPattern,
      );
      oldMap[entry.key] = parsed.text;
    }

    if (config.resolveLinked) {
      final refPat = RegExp(r'\{\{@:([\w.]+)\}\}');
      for (final key in oldMap.keys.toList()) {
        final val = oldMap[key]!;
        if (refPat.hasMatch(val)) {
          oldMap[key] = val.replaceAllMapped(refPat, (m) {
            final refPath = m.group(1)!;
            return oldMap[refPath] ?? m.group(0)!;
          });
        }
      }
    }

    final changed = <String>{};
    for (final entry in allKeys.entries) {
      final oldText = oldMap[entry.key];
      if (oldText == null || oldText != entry.value.text) {
        changed.add(entry.key);
      }
    }
    return changed;
  }

  Set<String> gitDeletedKeys(KeyMap allKeys) {
    final gitRel = config.entryFile.substring(gitRoot.length + 1);
    final oldContent = gitShowOld(gitRel);
    if (oldContent == null) return {};
    YamlMap? oldYaml2;
    try {
      oldYaml2 = loadYaml(oldContent) as YamlMap?;
    } catch (_) {
      return {};
    }
    if (oldYaml2 == null) return {};
    final oldRaw = YamlStringsParser.flattenYaml(oldYaml2);
    final oldDotKeys = oldRaw.keys.map(YamlStringsParser.dotToCamel).toSet();
    final curDotKeys = allKeys.keys.map(YamlStringsParser.dotToCamel).toSet();
    return oldDotKeys.difference(curDotKeys);
  }

  String? gitShowOld(String gitRelPath) {
    final result = Process.runSync('git', [
      'show',
      'HEAD:$gitRelPath',
    ], workingDirectory: gitRoot);
    if (result.exitCode != 0) return null;
    return result.stdout as String;
  }

  static String runGit(List<String> args, String cwd) {
    final result = Process.runSync('git', args, workingDirectory: cwd);
    if (result.exitCode != 0) {
      stderr.writeln('git ${args.join(' ')} failed: ${result.stderr}');
      exit(1);
    }
    return (result.stdout as String).trim();
  }
}
