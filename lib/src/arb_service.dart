import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'config.dart';
import 'models.dart';
import 'yaml_strings_parser.dart';

class ArbService {
  final LlmTranslateConfig config;

  ArbService(this.config);

  Map<String, dynamic> readArb(String locale) {
    final file = File('${config.arbDir}/${config.arbPrefix}$locale.arb');
    if (!file.existsSync()) return {'@@locale': locale};
    final content = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    return content;
  }

  Map<String, Map<String, dynamic>> extractArbMeta(Map<String, dynamic> arb) {
    final meta = <String, Map<String, dynamic>>{};
    for (final key in arb.keys) {
      if (key.startsWith('@') && !key.startsWith('@@')) {
        final baseKey = key.substring(1);
        final value = arb[key];
        if (value is Map<String, dynamic>) {
          meta[baseKey] = value;
        }
      }
    }
    return meta;
  }

  Map<String, dynamic>? genArbMeta(
    String dotKey,
    Map<String, String> paramTypes,
  ) {
    if (paramTypes.isEmpty) return null;
    final placeholders = <String, dynamic>{};
    for (final entry in paramTypes.entries) {
      placeholders[entry.key] = {'type': entry.value};
    }
    return {
      'description': 'Auto-generated for $dotKey',
      'placeholders': placeholders,
    };
  }

  /// Builds the authoritative ARB map for [locale] from the current
  /// `strings.yaml` keys. Values and `@key` metadata are regenerated from
  /// [allKeys], so keys deleted from `strings.yaml` disappear here.
  Map<String, dynamic> buildTemplateArb(KeyMap allKeys, String locale) {
    final arb = <String, dynamic>{'@@locale': locale};
    for (final entry in allKeys.entries) {
      final arbKey = YamlStringsParser.dotToCamel(entry.key);
      arb[arbKey] = entry.value.text;
      final meta = genArbMeta(entry.key, entry.value.paramTypes);
      if (meta != null) {
        arb['@$arbKey'] = meta;
      }
    }
    return arb;
  }

  /// ARB keys (values and their `@key` metadata) that no longer exist in
  /// [templateArb]. When [onlyPrefix] is given, only keys under that
  /// `strings.yaml` subtree are considered.
  Set<String> staleKeys(
    String locale,
    Map<String, dynamic> templateArb, {
    String? onlyPrefix,
  }) {
    final arb = readArb(locale);
    final validKeys = <String>{
      for (final key in templateArb.keys)
        if (!key.startsWith('@')) key,
    };
    final prefix = _onlyCamelPrefix(onlyPrefix);
    final stale = <String>{};
    for (final key in arb.keys) {
      if (key == '@@locale') continue;
      final baseKey = key.startsWith('@') ? key.substring(1) : key;
      if (validKeys.contains(baseKey)) continue;
      if (prefix != null && !_inScope(baseKey, prefix)) continue;
      stale.add(key);
    }
    return stale;
  }

  /// Removes [staleKeys] from the locale ARB file. Returns the number of
  /// removed entries (values and metadata counted separately).
  int pruneStaleKeys(
    String locale,
    Map<String, dynamic> templateArb, {
    String? onlyPrefix,
  }) {
    final stale = staleKeys(locale, templateArb, onlyPrefix: onlyPrefix);
    if (stale.isEmpty) return 0;
    final arb = readArb(locale);
    arb.removeWhere((key, _) => stale.contains(key));
    writeRawArb(arb, locale);
    return stale.length;
  }

  static String? _onlyCamelPrefix(String? onlyPrefix) {
    if (onlyPrefix == null || onlyPrefix.isEmpty) return null;
    return YamlStringsParser.dotToCamel(onlyPrefix);
  }

  static bool _inScope(String arbKey, String camelPrefix) =>
      arbKey == camelPrefix || arbKey.startsWith(camelPrefix);

  void cleanStaleKeys(
    Map<String, dynamic> targetArb,
    Map<String, dynamic> templateArb,
  ) {
    final validKeys = templateArb.keys.where((k) => !k.startsWith('@')).toSet();

    targetArb.removeWhere((key, _) {
      if (key == '@@locale') return false;
      final baseKey = key.startsWith('@') ? key.substring(1) : key;
      return !validKeys.contains(baseKey);
    });
  }

  void writeArb(
    Map<String, dynamic> existing,
    Map<String, String> newTranslations,
    Map<String, Map<String, dynamic>> arbMeta,
    String locale,
    Map<String, dynamic> templateArb,
  ) {
    final merged = Map<String, dynamic>.from(existing);
    cleanStaleKeys(merged, templateArb);
    for (final entry in newTranslations.entries) {
      merged[entry.key] = entry.value;
      if (arbMeta.containsKey(entry.key)) {
        merged['@${entry.key}'] = arbMeta[entry.key];
      }
    }
    writeRawArb(merged, locale);
  }

  void writeRawArb(Map<String, dynamic> arb, String locale) {
    final file = File('${config.arbDir}/${config.arbPrefix}$locale.arb');
    arb['@@locale'] = locale;
    final sorted = SplayTreeMap<String, dynamic>.from(arb, (a, b) {
      if (a == '@@locale') return -1;
      if (b == '@@locale') return 1;
      if (a.startsWith('@') && !b.startsWith('@')) return 1;
      if (b.startsWith('@') && !a.startsWith('@')) return -1;
      return a.compareTo(b);
    });
    final encoder = const JsonEncoder.withIndent('    ');
    file.writeAsStringSync('${encoder.convert(sorted)}\n');
  }

  List<Map<String, String>> buildReferenceContext({
    required Map<String, dynamic> engArb,
    required Map<String, dynamic> existing,
    required Map<String, String> batch,
    required String locale,
  }) {
    final referenceContext = <Map<String, String>>[];
    final seenPairs = <String>{};
    for (final entry in existing.entries) {
      final key = entry.key;
      if (key.startsWith('@')) continue;
      if (batch.containsKey(key)) continue;
      final enText = engArb[key] as String?;
      final targetText = entry.value as String?;
      if (enText != null && targetText != null) {
        final pairKey = '$enText -> $targetText';
        if (seenPairs.add(pairKey)) {
          referenceContext.add({'en': enText, locale: targetText});
        }
      }
    }
    return referenceContext;
  }
}
