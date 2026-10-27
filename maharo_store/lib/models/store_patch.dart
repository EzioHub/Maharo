import '../core/store_validation.dart';
import 'store_version.dart';

/// Delta patch metadata returned by the Store API.
class StorePatch {
  final String patchUrl;
  final int patchSizeBytes;
  final String patchSha256;
  final String fullApkSha256;
  final int fromVersionCode;
  final int toVersionCode;

  const StorePatch({
    required this.patchUrl,
    required this.patchSizeBytes,
    required this.patchSha256,
    required this.fullApkSha256,
    required this.fromVersionCode,
    required this.toVersionCode,
  });

  /// Throws on missing or mistyped fields (callers treat that as "no patch").
  factory StorePatch.fromJson(Map<String, dynamic> json) => StorePatch(
        patchUrl: json['patchUrl'] as String,
        patchSizeBytes: (json['patchSizeBytes'] as num).toInt(),
        patchSha256: json['patchSha256'] as String,
        fullApkSha256: json['fullApkSha256'] as String,
        fromVersionCode: (json['fromVersionCode'] as num).toInt(),
        toVersionCode: (json['toVersionCode'] as num).toInt(),
      );

  /// A patch is only used when it goes from exactly the installed version
  /// to exactly the release on screen, rebuilds the same APK hash that
  /// release announces, and has a well-formed hash and https URL.
  /// Otherwise the store does a full download.
  bool isUsableFor(StoreVersion latest, {required int installedVersionCode}) {
    if (installedVersionCode <= 0) return false;
    if (fromVersionCode != installedVersionCode) return false;
    if (toVersionCode != latest.versionCode) return false;
    final full = normalizeSha256(fullApkSha256);
    if (full == null || full != normalizeSha256(latest.sha256)) return false;
    if (normalizeSha256(patchSha256) == null) return false;
    if (parseHttpsUrl(patchUrl) == null) return false;
    return true;
  }
}
