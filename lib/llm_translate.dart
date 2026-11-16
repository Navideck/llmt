import 'dart:io';

import 'package:collection/collection.dart';
import 'src/arb_service.dart';
import 'src/config.dart';
import 'src/flutter_l10n_runner.dart';
import 'src/git_service.dart';
import 'src/llm_client.dart';
import 'src/models.dart';
import 'src/yaml_strings_parser.dart';

class LlmTranslate {
  static const String helpText = '''
Usage: llmt [options]

An LLM-powered translation pipeline producing ARB files for Flutter gen-l10n.

Options:
  -h, --help            Show this help message and exit
  --force               Force re-translation of all keys (bypasses git diff check)
  --verify              Run a second-pass QA review on translations
  --config <path>       Path to trconfig.yaml (default: ./trconfig.yaml)
  --endpoint <url>      LLM API endpoint URL (OpenAI-compatible)
  --model <model>       Model name for translation
  --verify-model <m>    Model name for verification pass (defaults to translation model)
  --api-key <key>       API key for authorization
  --env-file <path>     Path to explicit .env file
  --only <prefix>       Only translate keys under this top-level YAML subtree
  --header "K: V"       Add custom HTTP header (supports {session_id} / {uuid} macro)
''';

  final List<String> args;

  LlmTranslate({required this.args});

  late final bool _force = args.contains('--force');
  late final bool _verify = args.contains('--verify');
  late final String _cwd;
  late final LlmTranslateConfig _config;

  String? _getArg(String name) {
    final idx = args.indexOf(name);
    if (idx >= 0 && idx + 1 < args.length) {
      final val = args[idx + 1];
      if (!val.startsWith('--')) {
        return val;
      }
    }
    // Also support --name=value syntax
    final prefix = '$name=';
    for (final arg in args) {
      if (arg.startsWith(prefix)) {
        return arg.substring(prefix.length);
      }
    }
    return null;
  }

  List<String> _getMultipleArgs(String name) {
    final result = <String>[];
    final prefix = '$name=';
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (arg == name && i + 1 < args.length) {
        final val = args[i + 1];
        if (!val.startsWith('--')) {
          result.add(val);
          i++;
        }
      } else if (arg.startsWith(prefix)) {
        result.add(arg.substring(prefix.length));
      }
    }
    return result;
  }

  Map<String, String> _parseCliHeaders(List<String> rawHeaders) {
    final result = <String, String>{};
    for (final h in rawHeaders) {
      final separatorIdx = h.indexOf(RegExp(r'[:=]'));
      if (separatorIdx > 0) {
        final k = h.substring(0, separatorIdx).trim();
        final v = h.substring(separatorIdx + 1).trim();
        if (k.isNotEmpty) {
          result[k] = v;
        }
      }
    }
    return result;
  }

  Future<void> run() async {
    if (args.contains('--help') || args.contains('-h')) {
      print(helpText);
      return;
    }

    _cwd = Directory.current.path;
    final configPath = _getArg('--config') ?? '$_cwd/trconfig.yaml';
    final trconfFile = File(configPath).absolute;
    if (!trconfFile.existsSync()) {
      stderr.writeln('Config not found: $configPath');
      exit(1);
    }

    try {
      _config = LlmTranslateConfig.fromFile(
        trconfFile,
        endpoint: _getArg('--endpoint'),
        model: _getArg('--model'),
        verifyModel: _getArg('--verify-model'),
        apiKey: _getArg('--api-key'),
        envFile: _getArg('--env-file'),
        headers: _parseCliHeaders(_getMultipleArgs('--header')),
      );
    } catch (e) {
      stderr.writeln('Failed to load config: $e');
      exit(1);
    }

    final only = _getArg('--only');

    final parser = YamlStringsParser(_config);
    final allKeys = parser.parse();
    if (allKeys.isEmpty) {
      print('No translatable keys found.');
      return;
    }

    final gitService = GitService.fromCwd(_config, _cwd);
    final diff = gitService.diffAgainstHead(allKeys);

    final keysToTranslate = _force
        ? Map<String, KeyValue>.from(allKeys)
        : <String, KeyValue>{for (final k in diff.changed) k: allKeys[k]!};

    if (only != null && only.isNotEmpty) {
      keysToTranslate.removeWhere(
        (k, _) => !(k == only || k.startsWith('$only.')),
      );
    }

    final arbService = ArbService(_config);

    // Authoritative template ARB, rebuilt from strings.yaml. It also drives
    // pruning of stale keys in every locale, so removals are detected even
    // when they are the only change (or were committed earlier).
    final engArb = arbService.buildTemplateArb(allKeys, 'en');

    if (!_force && keysToTranslate.isEmpty) {
      final staleCount = _config.locales.fold<int>(
        0,
        (sum, locale) =>
            sum + arbService.staleKeys(locale, engArb, onlyPrefix: only).length,
      );
      if (staleCount == 0) {
        print('No changes detected. Use --force to force re-translate.');
        return;
      }
      print('No translation changes; pruning $staleCount stale key(s).');
    }

    if (diff.deleted.isNotEmpty) {
      print('Detected ${diff.deleted.length} removed key(s).');
    }

    arbService.writeRawArb(engArb, 'en');
    final arbMeta = arbService.extractArbMeta(engArb);

    final llmClient = LlmClient(_config);

    var hasErrors = false;

    for (final locale in _config.locales.where((l) => l != 'en')) {
      final batch = <String, String>{};
      for (final entry in keysToTranslate.entries) {
        batch[YamlStringsParser.dotToCamel(entry.key)] = entry.value.text;
      }

      if (batch.isEmpty) continue;
      final existing = arbService.readArb(locale);

      final referenceContext = arbService.buildReferenceContext(
        engArb: engArb,
        existing: existing,
        batch: batch,
        locale: locale,
      );

      print(
        'Translating ${batch.length} keys to $locale${only != null ? ' (only: $only)' : ''}...',
      );
      Map<String, String> translations;
      try {
        translations = await llmClient.translateBatch(
          batch,
          locale,
          referenceContext: referenceContext,
        );
      } catch (e) {
        hasErrors = true;
        stderr.writeln('Failed to translate to $locale: $e');
        stderr.writeln('Re-run to retry.');
        continue;
      }

      if (_verify) {
        print('Verifying $locale...');
        try {
          final fixes = await llmClient.verifyBatch(
            batch,
            translations,
            locale,
            referenceContext: referenceContext,
          );
          translations.addAll(fixes);
        } catch (e) {
          stderr.writeln('Verify failed for $locale: $e');
        }
      }

      arbService.writeArb(existing, translations, arbMeta, locale, engArb);

      for (final entry in translations.entries) {
        final enText = allKeys.entries
            .firstWhereOrNull(
              (e) => YamlStringsParser.dotToCamel(e.key) == entry.key,
            )
            ?.value
            .text;
        if (enText != null) {
          final enParams = YamlStringsParser.extractPlaceholders(enText);
          for (final p in enParams) {
            if (!entry.value.contains('{$p}')) {
              stderr.writeln('WARNING: $locale/${entry.key} missing \${$p}');
            }
          }
        }
      }

      print('  ✓ $locale done.');
    }

    // Reconcile every locale with the template so keys removed from
    // strings.yaml (now or in earlier commits) never survive in the ARBs.
    var pruned = 0;
    for (final locale in _config.locales) {
      pruned += arbService.pruneStaleKeys(locale, engArb, onlyPrefix: only);
    }
    if (pruned > 0) {
      print('Pruned $pruned stale key(s).');
    }

    FlutterL10nRunner.run(_config.configDir);

    if (hasErrors) {
      stderr.writeln('Completed with translation errors.');
      exit(1);
    }

    print('Done.');
  }
}
