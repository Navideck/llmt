import 'dart:convert';
import 'dart:math';
import 'package:collection/collection.dart';
import 'package:http/http.dart' as http;
import 'config.dart';

class LlmClient {
  final LlmTranslateConfig config;
  final http.Client _client;
  final String sessionId;

  LlmClient(this.config, {http.Client? client, String? sessionId})
    : _client = client ?? http.Client(),
      sessionId = sessionId ?? generateSessionId();

  static String generateSessionId() {
    final rand = Random.secure();
    final bytes = List<int>.generate(16, (_) => rand.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // Version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // Variant 10
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  Map<String, String> buildHeaders() {
    final apiKey = config.getApiKey();
    final headers = <String, String>{
      'Authorization': 'Bearer $apiKey',
      'Content-Type': 'application/json',
      'User-Agent': 'llmt/0.1.0',
    };
    for (final entry in config.customHeaders.entries) {
      final resolvedValue = entry.value
          .replaceAll('{session_id}', sessionId)
          .replaceAll('{uuid}', sessionId);
      headers[entry.key] = resolvedValue;
    }
    return headers;
  }

  static const Map<String, String> localeNames = {
    'de': 'German',
    'el': 'Greek',
    'hi': 'Hindi',
    'es': 'Spanish',
    'fr': 'French',
    'ja': 'Japanese',
    'zh': 'Chinese',
  };

  Future<Map<String, String>> translateBatch(
    Map<String, String> batch,
    String locale, {
    List<Map<String, String>> referenceContext = const [],
    String? model,
  }) async {
    final url = '${config.llmEndpoint}/chat/completions';
    final targetLanguage = localeNames[locale] ?? locale;
    final modelToUse = model ?? config.llmModel;

    final userContent = const JsonEncoder.withIndent('  ').convert(batch);

    final systemPrompt = [
      'You are a professional translator.',
      'Translate the JSON object under "Keys to translate" from English to $targetLanguage.',
      'Rules:',
      '- Output ONLY a flat JSON object mapping keys to translated strings (e.g. {"key": "translated text"}).',
      '- The JSON values MUST be simple strings, NOT maps, objects, or language tags.',
      '- Preserve all {placeholder} markers EXACTLY — do not translate them or change their case.',
      '- Leave international, technical, and industry standard terms untranslated when commonly used in target language (e.g. Take, FPS, ISO, LUT, Codec, Log, ND, Shutter).',
      '- Use natural, idiomatic language suitable for a mobile app UI.',
      if (referenceContext.isNotEmpty)
        '- Maintain terminology and style consistency with existing translations provided in reference context.',
      '- Do not include explanations or markdown formatting.',
    ].join('\n');

    final userPromptBuffer = StringBuffer();
    if (referenceContext.isNotEmpty) {
      final refJson = const JsonEncoder.withIndent(
        '  ',
      ).convert(referenceContext);
      userPromptBuffer.writeln(
        'Existing translations reference (English -> $targetLanguage):',
      );
      userPromptBuffer.writeln(refJson);
      userPromptBuffer.writeln();
    }
    userPromptBuffer.writeln('Keys to translate:');
    userPromptBuffer.writeln(userContent);

    final response = await _client.post(
      Uri.parse(url),
      headers: buildHeaders(),
      body: jsonEncode({
        'model': modelToUse,
        'messages': [
          {'role': 'system', 'content': systemPrompt},
          {'role': 'user', 'content': userPromptBuffer.toString()},
        ],
        'temperature': 0.3,
      }),
    );

    if (response.statusCode != 200) {
      throw Exception('API error ${response.statusCode}: ${response.body}');
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final content =
        (body['choices'] as List).first['message']['content'] as String;

    final jsonStr = sanitizeJsonString(content);
    return parseTranslationMap(jsonStr, locale);
  }

  Future<Map<String, String>> verifyBatch(
    Map<String, String> source,
    Map<String, String> translated,
    String locale, {
    List<Map<String, String>> referenceContext = const [],
  }) async {
    final url = '${config.llmEndpoint}/chat/completions';

    final pairs = <Map<String, String>>[];
    for (final key in source.keys) {
      pairs.add({'en': source[key] ?? '', 'tr': translated[key] ?? ''});
    }
    final pairsJson = const JsonEncoder.withIndent('  ').convert(pairs);

    final systemPrompt = [
      'You are a translation reviewer.',
      'Review English→locale translation pairs. For each pair:',
      '- Check accuracy and fluency.',
      '- Check {placeholders} are preserved exactly.',
      '- Ensure international, technical, and industry standard terms remain untranslated when appropriate.',
      if (referenceContext.isNotEmpty)
        '- Check terminology consistency against existing translations provided in reference context.',
      '- If a translation needs correction, provide the corrected version.',
      'Output ONLY a JSON object mapping key to corrected translation string (for keys that need fixing).',
      'If all translations are correct, output {}.',
    ].join('\n');

    final userPromptBuffer = StringBuffer();
    if (referenceContext.isNotEmpty) {
      final refJson = const JsonEncoder.withIndent(
        '  ',
      ).convert(referenceContext);
      userPromptBuffer.writeln('Existing translations reference:');
      userPromptBuffer.writeln(refJson);
      userPromptBuffer.writeln();
    }
    userPromptBuffer.writeln('Translation pairs to review:');
    userPromptBuffer.writeln(pairsJson);

    final response = await _client.post(
      Uri.parse(url),
      headers: buildHeaders(),
      body: jsonEncode({
        'model': config.verifyModel,
        'messages': [
          {'role': 'system', 'content': systemPrompt},
          {'role': 'user', 'content': userPromptBuffer.toString()},
        ],
        'temperature': 0.2,
      }),
    );

    if (response.statusCode != 200) {
      throw Exception('Verify API error ${response.statusCode}');
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final content =
        (body['choices'] as List).first['message']['content'] as String;

    final jsonStr = sanitizeJsonString(content);
    if (jsonStr == '{}') return {};
    return parseTranslationMap(jsonStr, locale);
  }

  static String sanitizeJsonString(String content) {
    return content
        .replaceFirst(RegExp(r'^```json\s*', multiLine: true), '')
        .replaceFirst(RegExp(r'^```\s*', multiLine: true), '')
        .replaceFirst(RegExp(r'\s*```$', multiLine: true), '')
        .trim();
  }

  static Map<String, String> parseTranslationMap(
    String jsonStr,
    String locale,
  ) {
    final rawMap = jsonDecode(jsonStr) as Map<String, dynamic>;
    final result = <String, String>{};
    for (final entry in rawMap.entries) {
      final key = entry.key;
      final val = entry.value;
      if (val is Map) {
        final extracted =
            val[locale]?.toString() ??
            val.values.firstOrNull?.toString() ??
            val.toString();
        result[key] = extracted;
      } else {
        var strVal = val.toString().trim();
        if (strVal.startsWith('{') && strVal.contains(':')) {
          final localeMatch = RegExp(
            RegExp.escape(locale) + r':\s*([^,}]+)',
          ).firstMatch(strVal);
          if (localeMatch != null) {
            strVal = localeMatch.group(1)!.trim();
          }
        }
        result[key] = strVal;
      }
    }
    return result;
  }
}
