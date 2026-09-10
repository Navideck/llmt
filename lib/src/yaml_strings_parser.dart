import 'dart:io';
import 'package:yaml/yaml.dart';
import 'config.dart';
import 'models.dart';

class YamlStringsParser {
  final LlmTranslateConfig config;

  YamlStringsParser(this.config);

  KeyMap parse() {
    final file = File(config.entryFile);
    if (!file.existsSync()) {
      return {};
    }

    final yamlContent = loadYaml(file.readAsStringSync()) as YamlMap?;
    if (yamlContent == null) return {};

    final raw = flattenYaml(yamlContent);
    final result = <String, KeyValue>{};

    for (final entry in raw.entries) {
      result[entry.key] = parseKey(entry.value, config.paramPattern);
    }

    if (config.resolveLinked) {
      final refPat = RegExp(r'\{\{@:([\w.]+)\}\}');
      // Resolve {{@:path}} links transitively, since a referenced message may
      // itself reference other messages (e.g. ...desc.background references
      // ...desc.foreground which references app.title). Also propagate the
      // referenced key's placeholder types so the generated ARB metadata
      // (@key placeholders) stays consistent with the template message text.
      // The pass count is bounded to guard against circular references.
      var remaining = result.length;
      var changed = true;
      while (changed && remaining-- > 0) {
        changed = false;
        for (final entry in result.entries) {
          if (refPat.hasMatch(entry.value.text)) {
            entry.value.text = entry.value.text.replaceAllMapped(refPat, (m) {
              final refPath = m.group(1)!;
              final ref = result[refPath];
              if (ref != null) {
                entry.value.paramTypes.addAll(ref.paramTypes);
              }
              return resolveRef(refPath, result) ?? m.group(0)!;
            });
            changed = true;
          }
        }
      }
    }

    result.removeWhere((k, _) => k.startsWith('fixed.'));

    return result;
  }

  static String? resolveRef(String path, Map<String, KeyValue> all) {
    final val = all[path];
    return val?.text.replaceAll(RegExp(r'\n\s{2}'), '\n');
  }

  static Map<String, String> flattenYaml(YamlMap root, [String prefix = '']) {
    final map = <String, String>{};
    for (final entry in root.entries) {
      final key = entry.key.toString();
      final fullKey = prefix.isEmpty ? key : '$prefix.$key';
      final val = entry.value;
      if (val is YamlMap) {
        map.addAll(flattenYaml(val, fullKey));
      } else if (val != null) {
        String text = val.toString().trimRight();
        map[fullKey] = text;
      }
    }
    return map;
  }

  static KeyValue parseKey(String raw, String paramPattern) {
    final paramTypes = <String, String>{};
    final paramPat = RegExp(r'\{\{(\w+):(\w+)\}\}');
    final matches = paramPat.allMatches(raw).toList();
    for (final m in matches) {
      paramTypes[m.group(1)!] = m.group(2)!;
    }

    String text = raw.replaceAllMapped(RegExp(r'\{\{(\w+)(?::\w+)?\}\}'), (m) {
      final name = m.group(1)!;
      return paramPattern.replaceAll('*', name);
    });

    return KeyValue(text: text, paramTypes: paramTypes);
  }

  static String dotToCamel(String dotKey) {
    final parts = dotKey.split('.');
    final sb = StringBuffer(segmentToCamel(parts[0], first: true));
    for (var i = 1; i < parts.length; i++) {
      sb.write(segmentToCamel(parts[i]));
    }
    return sb.toString();
  }

  static String segmentToCamel(String segment, {bool first = false}) {
    final parts = segment.split('_');
    final sb = StringBuffer(first ? parts[0] : capitalize(parts[0]));
    for (var i = 1; i < parts.length; i++) {
      sb.write(capitalize(parts[i]));
    }
    return sb.toString();
  }

  static String capitalize(String s) =>
      s.isEmpty ? '' : s[0].toUpperCase() + s.substring(1);

  static Set<String> extractPlaceholders(String text) {
    final matches = RegExp(r'\{(\w+)\}').allMatches(text);
    return matches.map((m) => m.group(1)!).toSet();
  }
}
