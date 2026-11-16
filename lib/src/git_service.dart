import 'dart:io';
import 'package:yaml/yaml.dart';
import 'config.dart';
import 'models.dart';
import 'yaml_strings_parser.dart';

/// Comparison of `strings.yaml` against git `HEAD`.
///
/// [changed] holds dot keys to (re)translate, [deleted] holds camelCase ARB
/// keys that no longer exist in `strings.yaml`.
typedef KeyDiff = ({Set<String> changed, Set<String> deleted});

class GitService {
  final LlmTranslateConfig config;
  final String gitRoot;
  final String cwd;

  GitService({required this.config, required this.gitRoot, required this.cwd});

  factory GitService.fromCwd(LlmTranslateConfig config, String cwd) {
    final gitRoot = runGit(['rev-parse', '--show-toplevel'], cwd);
    return GitService(config: config, gitRoot: gitRoot, cwd: cwd);
  }

  KeyDiff diffAgainstHead(KeyMap allKeys) {
    final gitRel = config.entryFile.substring(gitRoot.length + 1);
    final oldContent = gitShowOld(gitRel);
    if (oldContent == null) {
      print('No previous version in git. Translating all keys.');
      return (changed: allKeys.keys.toSet(), deleted: <String>{});
    }

    YamlMap? oldYaml;
    try {
      oldYaml = loadYaml(oldContent) as YamlMap?;
    } catch (e) {
      stderr.writeln(
        'Warning: could not parse git HEAD version of ${config.entryFile}, falling back to full translate.',
      );
      return (changed: allKeys.keys.toSet(), deleted: <String>{});
    }

    if (oldYaml == null) {
      return (changed: allKeys.keys.toSet(), deleted: <String>{});
    }

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

    return diffKeys(oldMap, allKeys);
  }

  /// Pure comparison so the diff semantics are testable without git.
  static KeyDiff diffKeys(Map<String, String> oldMap, KeyMap allKeys) {
    final changed = <String>{};
    for (final entry in allKeys.entries) {
      final oldText = oldMap[entry.key];
      if (oldText == null || oldText != entry.value.text) {
        changed.add(entry.key);
      }
    }

    final oldDotKeys = oldMap.keys.where((k) => !k.startsWith('fixed.'));
    final deleted = oldDotKeys
        .map(YamlStringsParser.dotToCamel)
        .toSet()
        .difference(allKeys.keys.map(YamlStringsParser.dotToCamel).toSet());

    return (changed: changed, deleted: deleted);
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
