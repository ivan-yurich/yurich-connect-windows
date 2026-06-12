class SecretRedactor {
  const SecretRedactor._();

  static String redact(String value) {
    return value
        .replaceAllMapped(
          RegExp(
            r'\b([0-9a-f]{4})[0-9a-f]{4}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{8}([0-9a-f]{4})\b',
            caseSensitive: false,
          ),
          (match) => '${match[1]}****${match[2]}',
        )
        .replaceAllMapped(
          RegExp(
            r'(vless://|naive\+https://|hysteria2://|hy2://|hysteria://)[^\s<>"]+',
            caseSensitive: false,
          ),
          (match) => '${match[1]}****',
        )
        .replaceAllMapped(
          RegExp(
            r'(https?://[^/\s]+)/(?:s|sub|subscription|api|link)/[^\s<>"]+',
            caseSensitive: false,
          ),
          (match) => '${match[1]}/.../****',
        )
        .replaceAllMapped(
          RegExp(r'(https?://)[^:@/\s]+:[^@/\s]+@', caseSensitive: false),
          (match) => '${match[1]}****:****@',
        )
        .replaceAllMapped(
          RegExp(
            r'("(?:password|passwd|token|access_token|refresh_token|uuid|auth|auth_str|private_key|public_key|short_id|shortId|subscription|server_credentials)"\s*:\s*")[^"]+',
            caseSensitive: false,
          ),
          (match) => '${match[1]}****',
        )
        .replaceAllMapped(
          RegExp(
            r'((?:password|passwd|token|access_token|refresh_token|auth|private_key|public_key|short_id|shortId|key)=)[^&\s]+',
            caseSensitive: false,
          ),
          (match) => '${match[1]}****',
        );
  }
}
