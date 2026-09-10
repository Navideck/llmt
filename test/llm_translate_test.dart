import 'dart:io';

import 'package:llmt/llmt.dart';
import 'package:llmt/src/config.dart';
import 'package:llmt/src/env_loader.dart';
import 'package:llmt/src/llm_client.dart';
import 'package:llmt/src/models.dart';
import 'package:llmt/src/yaml_strings_parser.dart';
import 'package:test/test.dart';

void main() {
  group('YamlStringsParser', () {
    test('dotToCamel converts dot and snake notation correctly', () {
      expect(YamlStringsParser.dotToCamel('slate.end_take'), 'slateEndTake');
      expect(YamlStringsParser.dotToCamel('camera_settings'), 'cameraSettings');
      expect(
        YamlStringsParser.dotToCamel('nav.header.title_text'),
        'navHeaderTitleText',
      );
    });

    test('parseKey extracts placeholders and formats output pattern', () {
      final parsed = YamlStringsParser.parseKey(
        'Recording {{duration:String}} at {{fps:int}} FPS',
        '{*}',
      );
      expect(parsed.text, 'Recording {duration} at {fps} FPS');
      expect(parsed.paramTypes, {'duration': 'String', 'fps': 'int'});
    });

    test('extractPlaceholders finds all placeholders in text', () {
      final placeholders = YamlStringsParser.extractPlaceholders(
        'Hello {name}, you have {count} messages.',
      );
      expect(placeholders, containsAll(['name', 'count']));
      expect(placeholders.length, 2);
    });

    test('resolveRef resolves linked key paths correctly', () {
      final all = {
        'common.app_name': KeyValue(text: 'Navideck', paramTypes: {}),
        'welcome': KeyValue(
          text: 'Welcome to {{@:common.app_name}}!',
          paramTypes: {},
        ),
      };
      final resolved = YamlStringsParser.resolveRef('common.app_name', all);
      expect(resolved, 'Navideck');
    });

    test('parse propagates placeholder types through linked references', () {
      final tempDir = Directory.systemTemp.createTempSync('parser_link_test_');
      addTearDown(() => tempDir.deleteSync(recursive: true));
      final stringsFile = File('${tempDir.path}/strings.yaml');
      stringsFile.writeAsStringSync('''
app:
  title: "{{appTitle:String}}"
drawer:
  feedback:
    message: We always try to improve {{@:app.title}}!
permission:
  volumedeck:
    location:
      desc:
        foreground: "{{@:app.title}} collects location data"
        background: "{{@:permission.volumedeck.location.desc.foreground}}, even when closed."
''');

      final config = LlmTranslateConfig(
        configPath: '${tempDir.path}/trconfig.yaml',
        configDir: tempDir.path,
        entryFile: '${tempDir.path}/strings.yaml',
        resolveLinked: true,
        paramPattern: '{*}',
        arbDir: 'lib/l10n',
        templateArbFile: 'intl_en.arb',
        arbPrefix: 'intl_',
        locales: {'en'},
        llmEndpoint: 'http://localhost:8000/v1',
        llmModel: 'dummy',
        verifyModel: 'dummy',
      );

      final parsed = YamlStringsParser(config).parse();

      final feedback = parsed['drawer.feedback.message']!;
      expect(feedback.text, 'We always try to improve {appTitle}!');
      expect(feedback.paramTypes, {'appTitle': 'String'});

      final background =
          parsed['permission.volumedeck.location.desc.background']!;
      expect(
        background.text,
        '{appTitle} collects location data, even when closed.',
      );
      expect(background.paramTypes, {'appTitle': 'String'});
    });
  });

  group('LlmClient', () {
    test('parseTranslationMap parses simple string map', () {
      const jsonStr = '{"slateEndTake": "Take beenden"}';
      final map = LlmClient.parseTranslationMap(jsonStr, 'de');
      expect(map['slateEndTake'], 'Take beenden');
    });

    test('parseTranslationMap unwraps nested map objects', () {
      const jsonStr =
          '{"slateEndTake": {"en": "End Take", "de": "Take beenden"}}';
      final map = LlmClient.parseTranslationMap(jsonStr, 'de');
      expect(map['slateEndTake'], 'Take beenden');
    });

    test('parseTranslationMap unwraps stringified map objects', () {
      const jsonStr = '{"slateEndTake": "{en: End Take, de: Take beenden}"}';
      final map = LlmClient.parseTranslationMap(jsonStr, 'de');
      expect(map['slateEndTake'], 'Take beenden');
    });

    test('sanitizeJsonString strips code fences', () {
      const input = '```json\n{"key": "value"}\n```';
      expect(LlmClient.sanitizeJsonString(input), '{"key": "value"}');
    });
  });

  group('EnvLoader', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('env_loader_test_');
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test('parseEnvFile parses comments, quotes, and export statements', () {
      final envFile = File('${tempDir.path}/.env');
      envFile.writeAsStringSync('''
# Comment line
export LLM_ENDPOINT="http://localhost:11434/v1"
LLM_MODEL='llama3.2' # inline comment
LLM_API_KEY=secret_key_123
''');

      final parsed = EnvLoader.parseEnvFile(envFile);
      expect(parsed['LLM_ENDPOINT'], 'http://localhost:11434/v1');
      expect(parsed['LLM_MODEL'], 'llama3.2');
      expect(parsed['LLM_API_KEY'], 'secret_key_123');
    });
  });

  group('LlmTranslateConfig precedence', () {
    late Directory tempDir;
    late File dummyTrConfig;
    late File dummyL10n;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('config_test_');
      dummyL10n = File('${tempDir.path}/l10n.yaml');
      dummyL10n.writeAsStringSync('''
arb-dir: lib/l10n
template-arb-file: app_en.arb
''');

      dummyTrConfig = File('${tempDir.path}/trconfig.yaml');
      dummyTrConfig.writeAsStringSync('''
entry_file: strings.yaml
locales:
  - en
  - de
llm:
  endpoint: http://yaml-endpoint/v1
  model: yaml-model
  verify_model: yaml-verify-model
  api_key: yaml-key
''');
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test('CLI flags take precedence over env vars and yaml', () {
      final config = LlmTranslateConfig.fromFile(
        dummyTrConfig,
        endpoint: 'http://cli-endpoint/v1',
        model: 'cli-model',
        verifyModel: 'cli-verify-model',
        apiKey: 'cli-key',
        overrideEnv: {
          'LLM_TRANSLATE_ENDPOINT': 'http://env-endpoint/v1',
          'LLM_TRANSLATE_MODEL': 'env-model',
          'LLM_TRANSLATE_VERIFY_MODEL': 'env-verify-model',
          'LLM_TRANSLATE_API_KEY': 'env-key',
        },
      );

      expect(config.llmEndpoint, 'http://cli-endpoint/v1');
      expect(config.llmModel, 'cli-model');
      expect(config.verifyModel, 'cli-verify-model');
      expect(config.getApiKey(), 'cli-key');
    });

    test(
      'Env vars take precedence over trconfig.yaml when no CLI flags provided',
      () {
        final config = LlmTranslateConfig.fromFile(
          dummyTrConfig,
          overrideEnv: {
            'LLM_TRANSLATE_ENDPOINT': 'http://env-endpoint/v1',
            'LLM_TRANSLATE_MODEL': 'env-model',
            'LLM_TRANSLATE_VERIFY_MODEL': 'env-verify-model',
            'LLM_TRANSLATE_API_KEY': 'env-key',
          },
        );

        expect(config.llmEndpoint, 'http://env-endpoint/v1');
        expect(config.llmModel, 'env-model');
        expect(config.verifyModel, 'env-verify-model');
        expect(config.getApiKey(), 'env-key');
      },
    );

    test(
      'api_key_env custom env var is honored when specified in trconfig.yaml',
      () {
        final customEnvTrConfig = File(
          '${tempDir.path}/custom_env_trconfig.yaml',
        );
        customEnvTrConfig.writeAsStringSync('''
entry_file: strings.yaml
locales:
  - en
llm:
  endpoint: http://yaml-endpoint/v1
  model: yaml-model
  api_key_env: CUSTOM_SECRET_KEY
''');

        final config = LlmTranslateConfig.fromFile(
          customEnvTrConfig,
          overrideEnv: {
            'LLM_TRANSLATE_API_KEY': '',
            'CUSTOM_SECRET_KEY': 'my-custom-secret',
          },
        );

        expect(config.getApiKey(), 'my-custom-secret');
      },
    );

    test('Fallback to trconfig.yaml when no CLI flags or env vars present', () {
      final emptyEnv = File('${tempDir.path}/empty.env')..createSync();
      final config = LlmTranslateConfig.fromFile(
        dummyTrConfig,
        envFile: emptyEnv.path,
        overrideEnv: {
          'LLM_ENDPOINT': '',
          'LLM_TRANSLATE_ENDPOINT': '',
          'LLM_MODEL': '',
          'LLM_TRANSLATE_MODEL': '',
          'LLM_VERIFY_MODEL': '',
          'LLM_TRANSLATE_VERIFY_MODEL': '',
          'LLM_TRANSLATE_API_KEY': '',
          'OPENCODE_GO_API_KEY': '',
          'OPENAI_API_KEY': '',
        },
      );

      expect(config.llmEndpoint, 'http://yaml-endpoint/v1');
      expect(config.llmModel, 'yaml-model');
      expect(config.verifyModel, 'yaml-verify-model');
      expect(config.getApiKey(), 'yaml-key');
    });

    test('Custom headers parse and respect precedence: yaml -> env -> CLI', () {
      final customHeadersYaml = File(
        '${tempDir.path}/custom_headers_trconfig.yaml',
      );
      customHeadersYaml.writeAsStringSync('''
entry_file: strings.yaml
locales:
  - en
llm:
  endpoint: http://yaml-endpoint/v1
  model: yaml-model
  headers:
    x-yaml-header: yaml-val
    x-override-me: from-yaml
''');

      final config = LlmTranslateConfig.fromFile(
        customHeadersYaml,
        headers: {'x-cli-header': 'cli-val', 'x-override-me': 'from-cli'},
        overrideEnv: {
          'LLM_TRANSLATE_HEADERS':
              '{"x-env-header": "env-val", "x-override-me": "from-env"}',
        },
      );

      expect(config.customHeaders['x-yaml-header'], 'yaml-val');
      expect(config.customHeaders['x-env-header'], 'env-val');
      expect(config.customHeaders['x-cli-header'], 'cli-val');
      expect(config.customHeaders['x-override-me'], 'from-cli');
    });
  });

  group('LlmClient headers and session ID', () {
    test(
      'buildHeaders includes defaults, custom headers, and resolves session_id/uuid macros',
      () {
        final config = LlmTranslateConfig(
          configPath: '/dummy/trconfig.yaml',
          configDir: '/dummy',
          entryFile: '/dummy/strings.yaml',
          resolveLinked: true,
          paramPattern: '{*}',
          arbDir: '/dummy/l10n',
          templateArbFile: 'app_en.arb',
          arbPrefix: 'app_',
          locales: {'en', 'de'},
          llmEndpoint: 'https://example.com/v1',
          llmApiKey: 'my-api-key',
          llmModel: 'test-model',
          verifyModel: 'test-verify-model',
          customHeaders: {
            'x-opencode-session': '{session_id}',
            'x-trace-id': '{uuid}',
            'x-custom-static': 'static-val',
          },
        );

        final client = LlmClient(config, sessionId: 'stable-test-session-123');
        final headers = client.buildHeaders();

        expect(headers['Authorization'], 'Bearer my-api-key');
        expect(headers['Content-Type'], 'application/json');
        expect(headers['User-Agent'], 'llmt/0.1.0');
        expect(headers['x-opencode-session'], 'stable-test-session-123');
        expect(headers['x-trace-id'], 'stable-test-session-123');
        expect(headers['x-custom-static'], 'static-val');
      },
    );

    test('LlmClient generates valid UUID session ID by default', () {
      final config = LlmTranslateConfig(
        configPath: '/dummy/trconfig.yaml',
        configDir: '/dummy',
        entryFile: '/dummy/strings.yaml',
        resolveLinked: true,
        paramPattern: '{*}',
        arbDir: '/dummy/l10n',
        templateArbFile: 'app_en.arb',
        arbPrefix: 'app_',
        locales: {'en', 'de'},
        llmEndpoint: 'https://example.com/v1',
        llmApiKey: 'my-api-key',
        llmModel: 'test-model',
        verifyModel: 'test-verify-model',
      );

      final client = LlmClient(config);
      expect(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ).hasMatch(client.sessionId),
        true,
      );
    });
  });

  group('Subtree filtering (--only)', () {
    test('filters keys matching top-level subtree prefix', () {
      final allKeys = {
        'paywallOfferings.pro.placeholder': KeyValue(
          text: 'Pro',
          paramTypes: {},
        ),
        'paywallOfferings.ultimate.title': KeyValue(
          text: 'Ultimate',
          paramTypes: {},
        ),
        'plist.NSBluetoothAlwaysUsageDescription': KeyValue(
          text: 'Bluetooth',
          paramTypes: {},
        ),
      };

      const only = 'paywallOfferings';
      final filtered = Map<String, KeyValue>.from(allKeys)
        ..removeWhere((k, _) => !(k == only || k.startsWith('$only.')));

      expect(
        filtered.keys,
        containsAll([
          'paywallOfferings.pro.placeholder',
          'paywallOfferings.ultimate.title',
        ]),
      );
      expect(
        filtered.containsKey('plist.NSBluetoothAlwaysUsageDescription'),
        false,
      );
    });
  });

  group('LlmTranslate CLI help & OpenCode fallback', () {
    test('LlmTranslate.helpText documents core flags', () {
      expect(LlmTranslate.helpText, contains('--help'));
      expect(LlmTranslate.helpText, contains('--force'));
      expect(LlmTranslate.helpText, contains('--verify'));
      expect(LlmTranslate.helpText, contains('--endpoint'));
      expect(LlmTranslate.helpText, contains('--model'));
      expect(LlmTranslate.helpText, contains('--api-key'));
      expect(LlmTranslate.helpText, contains('--only'));
      expect(LlmTranslate.helpText, contains('--header'));
    });

    test(
      'OpenCode auto-discovery loads key from auth.json when using opencode endpoint',
      () {
        final tempDir = Directory.systemTemp.createTempSync('opencode_test');
        try {
          final authDir = Directory('${tempDir.path}/.local/share/opencode');
          authDir.createSync(recursive: true);
          final authFile = File('${authDir.path}/auth.json');
          authFile.writeAsStringSync(
            '{"opencode-go": {"key": "test-auto-discovered-opencode-key"}}',
          );

          final config = LlmTranslateConfig(
            configPath: '/dummy/trconfig.yaml',
            configDir: '/dummy',
            entryFile: '/dummy/strings.yaml',
            resolveLinked: true,
            paramPattern: '{*}',
            arbDir: '/dummy/l10n',
            templateArbFile: 'app_en.arb',
            arbPrefix: 'app_',
            locales: {'en', 'de'},
            llmEndpoint: 'https://opencode.ai/zen/go/v1',
            llmModel: 'deepseek-v4-flash',
            verifyModel: 'deepseek-v4-flash',
          );

          final key = config.getApiKey(customHome: tempDir.path);
          expect(key, 'test-auto-discovered-opencode-key');
        } finally {
          tempDir.deleteSync(recursive: true);
        }
      },
    );
  });
}
