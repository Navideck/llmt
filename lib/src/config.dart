import 'dart:convert';
import 'dart:io';
import 'package:yaml/yaml.dart';
import 'env_loader.dart';

class LlmTranslateConfig {
  final String configPath;
  final String configDir;
  final String entryFile;
  final bool resolveLinked;
  final String paramPattern;
  final String arbDir;
  final String templateArbFile;
  final String arbPrefix;
  final Set<String> locales;

  final String llmEndpoint;
  final String? llmApiKeyEnv;
  final String? llmApiKey;
  final String? _cliApiKey;
  final String llmModel;
  final String verifyModel;
  final Map<String, String> customHeaders;

  final Map<String, String> _mergedEnv;

  LlmTranslateConfig({
    required this.configPath,
    required this.configDir,
    required this.entryFile,
    required this.resolveLinked,
    required this.paramPattern,
    required this.arbDir,
    required this.templateArbFile,
    required this.arbPrefix,
    required this.locales,
    required this.llmEndpoint,
    this.llmApiKeyEnv,
    this.llmApiKey,
    String? cliApiKey,
    required this.llmModel,
    required this.verifyModel,
    Map<String, String>? customHeaders,
    Map<String, String>? mergedEnv,
  }) : _cliApiKey = cliApiKey,
       customHeaders = customHeaders ?? const {},
       _mergedEnv = mergedEnv ?? {};

  factory LlmTranslateConfig.fromFile(
    File trconfFile, {
    String? endpoint,
    String? model,
    String? verifyModel,
    String? apiKey,
    String? envFile,
    Map<String, String>? headers,
    Map<String, String>? overrideEnv,
  }) {
    if (!trconfFile.existsSync()) {
      throw FileSystemException('Config not found', trconfFile.path);
    }

    final trconf = loadYaml(trconfFile.readAsStringSync()) as YamlMap;
    final configDir = trconfFile.parent.path;
    final entryFile = '$configDir/${trconf['entry_file']}';

    final l10nPath = '$configDir/l10n.yaml';
    final l10nFile = File(l10nPath);
    if (!l10nFile.existsSync()) {
      throw FileSystemException('l10n.yaml not found', l10nPath);
    }

    final l10n = loadYaml(l10nFile.readAsStringSync()) as YamlMap;
    final arbDir = '$configDir/${l10n['arb-dir']}';
    final templateArbFile = l10n['template-arb-file'] as String;

    final templateMatch = RegExp(
      r'^(.+?)([a-z]{2})\.arb$',
    ).firstMatch(templateArbFile);
    if (templateMatch == null) {
      throw FormatException(
        'Cannot parse template ARB filename: $templateArbFile',
      );
    }

    final arbPrefix = templateMatch.group(1)!;
    final templateLocale = templateMatch.group(2)!;

    final resolveLinked = trconf['resolve_linked_keys'] == true;
    final paramPattern = trconf['param_output_pattern'] as String? ?? '{*}';
    final localesYaml = trconf['locales'] as List<dynamic>?;
    final locales = (localesYaml ?? [templateLocale])
        .map((l) => l.toString())
        .toSet();

    // Build merged env: loaded .env files + system Platform.environment + optional overrideEnv
    final fileEnvs = EnvLoader.loadEnv(explicitEnvFile: envFile);
    final mergedEnv = <String, String>{
      ...fileEnvs,
      ...Platform.environment,
      if (overrideEnv != null) ...overrideEnv,
    };

    final llm = trconf['llm'] as YamlMap?;

    // Resolution priority: 1. CLI flag -> 2. Env / .env -> 3. trconfig.yaml
    final finalEndpoint = _firstNonEmpty([
      endpoint,
      mergedEnv['LLM_TRANSLATE_ENDPOINT'],
      mergedEnv['LLM_ENDPOINT'],
      llm?['endpoint'] as String?,
    ]);

    if (finalEndpoint == null) {
      throw FormatException(
        'Missing LLM endpoint. Provide via CLI (--endpoint), env (LLM_TRANSLATE_ENDPOINT), or "llm.endpoint" in ${trconfFile.path}',
      );
    }

    final finalModel = _firstNonEmpty([
      model,
      mergedEnv['LLM_TRANSLATE_MODEL'],
      mergedEnv['LLM_MODEL'],
      llm?['model'] as String?,
    ]);

    if (finalModel == null) {
      throw FormatException(
        'Missing LLM model. Provide via CLI (--model), env (LLM_TRANSLATE_MODEL), or "llm.model" in ${trconfFile.path}',
      );
    }

    final finalVerifyModel = _firstNonEmpty([
      verifyModel,
      mergedEnv['LLM_TRANSLATE_VERIFY_MODEL'],
      mergedEnv['LLM_VERIFY_MODEL'],
      llm?['verify_model'] as String?,
      finalModel,
    ])!;

    final llmApiKey = llm?['api_key'] as String?;
    final llmApiKeyEnv = llm?['api_key_env'] as String?;

    // Headers priority: trconfig.yaml -> env (LLM_TRANSLATE_HEADERS / LLM_HEADERS) -> CLI/parameter
    final yamlHeaders = <String, String>{};
    final rawYamlHeaders = llm?['headers'];
    if (rawYamlHeaders is Map) {
      for (final entry in rawYamlHeaders.entries) {
        if (entry.key != null && entry.value != null) {
          yamlHeaders[entry.key.toString()] = entry.value.toString();
        }
      }
    }

    final envHeaders = _parseHeadersString(
      _firstNonEmpty([
        mergedEnv['LLM_TRANSLATE_HEADERS'],
        mergedEnv['LLM_HEADERS'],
      ]),
    );

    final mergedHeaders = <String, String>{
      ...yamlHeaders,
      ...envHeaders,
      if (headers != null) ...headers,
    };

    return LlmTranslateConfig(
      configPath: trconfFile.path,
      configDir: configDir,
      entryFile: entryFile,
      resolveLinked: resolveLinked,
      paramPattern: paramPattern,
      arbDir: arbDir,
      templateArbFile: templateArbFile,
      arbPrefix: arbPrefix,
      locales: locales,
      llmEndpoint: finalEndpoint,
      llmApiKeyEnv: llmApiKeyEnv,
      llmApiKey: llmApiKey,
      cliApiKey: apiKey,
      llmModel: finalModel,
      verifyModel: finalVerifyModel,
      customHeaders: mergedHeaders,
      mergedEnv: mergedEnv,
    );
  }

  static Map<String, String> _parseHeadersString(String? raw) {
    if (raw == null || raw.trim().isEmpty) return {};
    final trimmed = raw.trim();
    if (trimmed.startsWith('{') && trimmed.endsWith('}')) {
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map) {
          return {
            for (final entry in decoded.entries)
              entry.key.toString(): entry.value.toString(),
          };
        }
      } catch (_) {}
    }

    final result = <String, String>{};
    final pairs = trimmed.split(RegExp(r'[\r\n,]+'));
    for (final pair in pairs) {
      final p = pair.trim();
      if (p.isEmpty) continue;
      final separatorIdx = p.indexOf(RegExp(r'[:=]'));
      if (separatorIdx > 0) {
        final k = p.substring(0, separatorIdx).trim();
        final v = p.substring(separatorIdx + 1).trim();
        if (k.isNotEmpty) {
          result[k] = v;
        }
      }
    }
    return result;
  }

  static String? _firstNonEmpty(List<String?> items) {
    for (final item in items) {
      if (item != null && item.isNotEmpty) {
        return item;
      }
    }
    return null;
  }

  String getApiKey({String? customHome}) {
    // 1. CLI argument
    final cliKey = _cliApiKey;
    if (cliKey != null && cliKey.isNotEmpty) {
      return cliKey;
    }

    // 2. Environment variable / .env (LLM_TRANSLATE_API_KEY)
    final defaultEnvKey = _mergedEnv['LLM_TRANSLATE_API_KEY'];
    if (defaultEnvKey != null && defaultEnvKey.isNotEmpty) {
      return defaultEnvKey;
    }

    // 3. Custom environment variable from trconfig.yaml (api_key_env)
    final envVarName = llmApiKeyEnv;
    if (envVarName != null && envVarName.isNotEmpty) {
      final customEnvKey = _mergedEnv[envVarName];
      if (customEnvKey != null && customEnvKey.isNotEmpty) {
        return customEnvKey;
      }
    }

    // 4. Direct API key in trconfig.yaml
    final key = llmApiKey;
    if (key != null && key.isNotEmpty) {
      return key;
    }

    // 5. Fallback: Auto-detect from ~/.local/share/opencode/auth.json if endpoint is OpenCode
    if (llmEndpoint.contains('opencode.ai')) {
      final openCodeKey = loadOpenCodeApiKey(customHome: customHome);
      if (openCodeKey != null && openCodeKey.isNotEmpty) {
        return openCodeKey;
      }
    }

    return 'not-needed';
  }

  static String? loadOpenCodeApiKey({String? customHome}) {
    final home =
        customHome ??
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'];
    if (home == null || home.isEmpty) return null;
    final file = File('$home/.local/share/opencode/auth.json');
    if (!file.existsSync()) return null;
    try {
      final content = file.readAsStringSync();
      final json = jsonDecode(content);
      if (json is Map) {
        final opencodeGo = json['opencode-go'];
        if (opencodeGo is Map) {
          final key = opencodeGo['key']?.toString();
          if (key != null && key.isNotEmpty) {
            return key;
          }
        }
      }
    } catch (_) {}
    return null;
  }
}
