import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

class WindowsAuthenticodeInfo {
  const WindowsAuthenticodeInfo({
    required this.status,
    this.thumbprint,
    this.subject,
  });

  final String status;
  final String? thumbprint;
  final String? subject;

  bool get isValid => status.toLowerCase() == 'valid';

  bool get isNotSigned => status.toLowerCase() == 'notsigned';
}

class WindowsUpdateIntegrity {
  static final RegExp _sha256Pattern = RegExp(r'^[a-fA-F0-9]{64}$');
  static final RegExp _checksumLinePattern = RegExp(
    r'^([a-fA-F0-9]{64})\s+[*]?(.+?)\s*$',
  );

  static String? normalizeSha256(String? value) {
    if (value == null) {
      return null;
    }
    var normalized = value.trim();
    if (normalized.toLowerCase().startsWith('sha256:')) {
      normalized = normalized.substring('sha256:'.length).trim();
    }
    if (!_sha256Pattern.hasMatch(normalized)) {
      return null;
    }
    return normalized.toLowerCase();
  }

  static String? checksumForFile(String content, String fileName) {
    final wantedName = _baseName(fileName).toLowerCase();
    final matches = <String>{};
    for (final rawLine in const LineSplitter().convert(content)) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) {
        continue;
      }
      final match = _checksumLinePattern.firstMatch(line);
      if (match == null) {
        continue;
      }
      final candidateName = _baseName(
        match.group(2)!.replaceAll('"', '').trim(),
      ).toLowerCase();
      if (candidateName == wantedName) {
        matches.add(match.group(1)!.toLowerCase());
      }
    }
    return matches.length == 1 ? matches.single : null;
  }

  static Future<String> sha256ForFile(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString().toLowerCase();
  }

  static Future<bool> fileMatchesSha256(File file, String expected) async {
    final normalized = normalizeSha256(expected);
    if (normalized == null || !await file.exists()) {
      return false;
    }
    return await sha256ForFile(file) == normalized;
  }

  static WindowsAuthenticodeInfo? parseAuthenticodeJson(String output) {
    final trimmed = output.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is! Map) {
        return null;
      }
      final json = decoded.cast<String, dynamic>();
      final status = '${json['status'] ?? ''}'.trim();
      if (status.isEmpty) {
        return null;
      }
      final thumbprint = '${json['thumbprint'] ?? ''}'.trim();
      final subject = '${json['subject'] ?? ''}'.trim();
      return WindowsAuthenticodeInfo(
        status: status,
        thumbprint: thumbprint.isEmpty ? null : thumbprint.toUpperCase(),
        subject: subject.isEmpty ? null : subject,
      );
    } on FormatException {
      return null;
    }
  }

  static String? authenticodePolicyError({
    required WindowsAuthenticodeInfo currentApp,
    required WindowsAuthenticodeInfo installer,
  }) {
    if (!currentApp.isValid && !currentApp.isNotSigned) {
      return 'Current app Authenticode status is ${currentApp.status}.';
    }
    if (!installer.isValid && !installer.isNotSigned) {
      return 'Installer Authenticode status is ${installer.status}.';
    }
    if (!currentApp.isValid) {
      return null;
    }
    if (!installer.isValid) {
      return 'A signed Yurich Connect build cannot install an unsigned update.';
    }
    final currentThumbprint = currentApp.thumbprint?.toUpperCase();
    final installerThumbprint = installer.thumbprint?.toUpperCase();
    if (currentThumbprint == null || installerThumbprint == null) {
      return 'Could not verify the update signer certificate.';
    }
    if (currentThumbprint != installerThumbprint) {
      return 'The update was signed by a different publisher certificate.';
    }
    return null;
  }

  static String _baseName(String path) {
    final normalized = path.replaceAll('\\', '/');
    final separator = normalized.lastIndexOf('/');
    return separator < 0 ? normalized : normalized.substring(separator + 1);
  }
}
