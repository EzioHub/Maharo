// Validation for Store metadata. The Maharo API is the source of these
// values, but the store still treats them as untrusted input: nothing is
// downloaded or installed unless they are well formed.

final RegExp _sha256Hex = RegExp(r'^[0-9a-f]{64}$');

/// Trims and lower-cases [value]; returns it only when it is exactly 64 hex
/// characters (a SHA-256 digest), otherwise null.
String? normalizeSha256(String? value) {
  if (value == null) return null;
  final v = value.trim().toLowerCase();
  return _sha256Hex.hasMatch(v) ? v : null;
}

/// True when [value] is a well-formed SHA-256 hex digest.
bool isValidSha256(String? value) => normalizeSha256(value) != null;

/// Parses [value] as an absolute `https` URL with a host and without user
/// info; returns null for anything else (http, relative, file:, ...).
Uri? parseHttpsUrl(String? value) {
  if (value == null) return null;
  final uri = Uri.tryParse(value.trim());
  if (uri == null || !uri.isAbsolute) return null;
  if (uri.scheme.toLowerCase() != 'https') return null;
  if (uri.host.isEmpty || uri.userInfo.isNotEmpty) return null;
  return uri;
}
