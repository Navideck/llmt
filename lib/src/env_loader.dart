import 'dart:io';

class EnvLoader {
  /// Loads environment variables from `.env` files found in:
  /// 1. [explicitEnvFile] if provided and exists
  /// 2. Working directory `./.env`
  /// 3. Parent directories up to Git repository root
  /// 4. User home directory (`~/.env` or `~/.config/llm_translate/.env`)
  ///
  /// Merges variables so that closer `.env` files override higher-level ones.
  /// Does NOT modify system [Platform.environment]. Returns a combined map.
  static Map<String, String> loadEnv({String? explicitEnvFile}) {
    final merged = <String, String>{};

    final filesToLoad = <File>[];

    // 1. Home directory configs (lowest precedence among .env files)
    final home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    if (home != null && home.isNotEmpty) {
      final homeConfigEnv = File('$home/.config/llm_translate/.env');
      if (homeConfigEnv.existsSync()) {
        filesToLoad.add(homeConfigEnv);
      }
      final homeConfigLlmtEnv = File('$home/.config/llmt/.env');
      if (homeConfigLlmtEnv.existsSync()) {
        filesToLoad.add(homeConfigLlmtEnv);
      }
      final homeEnv = File('$home/.env');
      if (homeEnv.existsSync()) {
        filesToLoad.add(homeEnv);
      }
    }

    // 2. Directory tree up to Git root / filesystem root
    var currentDir = Directory.current.absolute;
    final treeEnvs = <File>[];

    while (true) {
      final envFile = File('${currentDir.path}/.env');
      if (envFile.existsSync()) {
        treeEnvs.add(envFile);
      }

      final isGitRoot =
          FileSystemEntity.typeSync('${currentDir.path}/.git') !=
          FileSystemEntityType.notFound;
      final parent = currentDir.parent;
      if (isGitRoot || parent.path == currentDir.path) {
        break;
      }
      currentDir = parent;
    }

    // Add tree envs in root -> leaf order so closer .env overrides higher
    filesToLoad.addAll(treeEnvs.reversed);

    // 3. Explicit env file (highest precedence among .env files)
    if (explicitEnvFile != null && explicitEnvFile.isNotEmpty) {
      final explicit = File(explicitEnvFile);
      if (explicit.existsSync()) {
        filesToLoad.add(explicit);
      }
    }

    for (final file in filesToLoad) {
      merged.addAll(parseEnvFile(file));
    }

    return merged;
  }

  /// Parses a `.env` file into key-value map.
  static Map<String, String> parseEnvFile(File file) {
    final result = <String, String>{};
    if (!file.existsSync()) return result;

    final lines = file.readAsLinesSync();
    for (var line in lines) {
      line = line.trim();
      if (line.isEmpty || line.startsWith('#')) continue;

      if (line.startsWith('export ')) {
        line = line.substring(7).trim();
      }

      final equalsIdx = line.indexOf('=');
      if (equalsIdx == -1) continue;

      final key = line.substring(0, equalsIdx).trim();
      var value = line.substring(equalsIdx + 1).trim();

      if (key.isEmpty) continue;

      // Handle quotes and inline comments properly
      if ((value.startsWith('"') && value.contains('"', 1)) ||
          (value.startsWith("'") && value.contains("'", 1))) {
        final quoteChar = value[0];
        final closingIdx = value.indexOf(quoteChar, 1);
        if (closingIdx != -1) {
          value = value.substring(1, closingIdx);
        }
      } else {
        final commentIdx = value.indexOf('#');
        if (commentIdx != -1) {
          value = value.substring(0, commentIdx).trim();
        }
      }

      result[key] = value;
    }

    return result;
  }
}
