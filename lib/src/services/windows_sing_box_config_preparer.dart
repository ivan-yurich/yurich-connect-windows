import 'dart:convert';

class WindowsSingBoxConfigPreparer {
  const WindowsSingBoxConfigPreparer._();

  static String withWritableCachePath(
    String config, {
    required String cacheFilePath,
  }) {
    final normalizedPath = cacheFilePath.trim();
    if (normalizedPath.isEmpty) {
      return config;
    }

    Object? decoded;
    try {
      decoded = jsonDecode(config);
    } on Object {
      return config;
    }
    if (decoded is! Map) {
      return config;
    }

    final root = decoded.cast<String, dynamic>();
    final experimental = root['experimental'];
    if (experimental is! Map) {
      return config;
    }
    final cacheFile = experimental['cache_file'];
    if (cacheFile is! Map || cacheFile['enabled'] != true) {
      return config;
    }

    cacheFile['path'] = normalizedPath;
    return const JsonEncoder.withIndent('  ').convert(root);
  }
}
