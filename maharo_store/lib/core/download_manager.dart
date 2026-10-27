import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'bspatch.dart';
import 'package_service.dart';
import 'store_validation.dart';

/// Applies a BSDIFF40 patch; returns false on any failure.
typedef PatchApplier = Future<bool> Function({
  required File oldFile,
  required File patchFile,
  required File newFile,
  int? expectedNewSize,
});

/// Download engine with three guarantees:
///
/// 1. **Background-safe**: while the store is merely backgrounded / the user
///    switched apps, a tiny foreground service keeps the process alive so
///    the transfer never pauses.
/// 2. **Resumable across full app closes**: bytes stream directly into the
///    single APK slot on disk. If the app is killed at 50%, those bytes are
///    still there — reopening and tapping Install/Resume continues via an
///    HTTP Range request from exactly where it stopped (nginx supports
///    ranges).
/// 3. **Single-APK policy**: at most one APK file exists on the device.
///
/// Integrity: release metadata (SHA-256, URLs) is validated before anything
/// is downloaded, the APK is staged in the app's private internal storage,
/// re-verified before every install attempt, and the native installer hashes
/// the bytes again while streaming them into the PackageInstaller session.
class DownloadManager {
  static final DownloadManager _instance = DownloadManager._internal();
  factory DownloadManager() => _instance;

  DownloadManager._internal()
      : this._(
          dio: Dio()..options.connectTimeout = const Duration(seconds: 20),
          stagingDir: _defaultStagingDir,
          legacyDir: _defaultLegacyDir,
          native: const ChannelStoreNative(),
          idleTimeout: defaultIdleTimeout,
          installDelay: const Duration(milliseconds: 300),
          applyPatch: Bspatch.apply,
        );

  /// Test seam: inject the HTTP client, the staging directory, the native
  /// channel and the patcher.
  @visibleForTesting
  DownloadManager.forTesting({
    required Dio dio,
    required Future<Directory> Function() stagingDir,
    Future<Directory?> Function()? legacyDir,
    required StoreNative native,
    Duration idleTimeout = defaultIdleTimeout,
    Duration installDelay = Duration.zero,
    PatchApplier applyPatch = Bspatch.apply,
  }) : this._(
          dio: dio,
          stagingDir: stagingDir,
          legacyDir: legacyDir ?? _noLegacyDir,
          native: native,
          idleTimeout: idleTimeout,
          installDelay: installDelay,
          applyPatch: applyPatch,
        );

  DownloadManager._({
    required Dio dio,
    required Future<Directory> Function() stagingDir,
    required Future<Directory?> Function() legacyDir,
    required StoreNative native,
    required Duration idleTimeout,
    required Duration installDelay,
    required PatchApplier applyPatch,
  })  : _dio = dio,
        _stagingDirProvider = stagingDir,
        _legacyDirProvider = legacyDir,
        _native = native,
        _idleTimeout = idleTimeout,
        _installDelay = installDelay,
        _applyPatch = applyPatch;

  final Dio _dio;
  final Future<Directory> Function() _stagingDirProvider;
  final Future<Directory?> Function() _legacyDirProvider;
  final StoreNative _native;

  /// Longest gap between two received chunks before the transfer counts as
  /// stalled (Dio's `receiveTimeout`, which it applies between chunks).
  final Duration _idleTimeout;
  final Duration _installDelay;
  final PatchApplier _applyPatch;

  CancelToken? _cancelToken;
  bool _serviceRunning = false;
  bool _pausedByUser = false;
  double _lastProgress = 0.0;

  /// lastUpdateTime of `app.maharo` captured just before the system installer
  /// was opened. The UI re-checks it on resume: if the timestamp is unchanged,
  /// nothing was installed (user cancelled or Android refused the update).
  int installBaselineTime = 0;

  /// Install-outcome events: 'installed' (install session succeeded — the
  /// UI refreshes to "Open" immediately) and 'needs_user' (Android wants a
  /// confirm dialog but the store was in the background — the verified APK
  /// stays on disk and the installer re-opens when the user returns).
  final StreamController<String> installEvents = StreamController<String>.broadcast();

  /// The one and only APK file the store is allowed to keep. While a
  /// download is in flight (or interrupted), this same path holds the
  /// PARTIAL bytes — that is what makes resume possible.
  static const apkFileName = 'maharo-latest.apk';
  static const patchFileName = 'maharo-patch.bsdiff';
  static const patchTmpFileName = 'maharo-patching.tmp';

  /// Staging folder under the app's private files dir. Must match
  /// `STAGING_DIR` in MainActivity.kt, which refuses APKs from anywhere else.
  static const stagingSubdir = 'apk';

  /// The only package this store installs.
  static const targetPackage = 'app.maharo';

  /// Largest APK (or patch) the store accepts.
  static const maxApkBytes = Bspatch.defaultMaxNewSize;

  static const defaultIdleTimeout = Duration(seconds: 45);

  static const _metaKey = 'maharo_dl_meta';
  static const _verifiedKey = 'maharo_dl_verified';

  static const msgMissingHash =
      'Security error: this release has no valid SHA-256 hash. Download blocked.';
  static const msgInsecureUrl =
      'Security error: the download link is not a secure https URL. Download blocked.';
  static const msgInstallsDisabled =
      'Installs are disabled in this Store build: the trusted Maharo signing '
      'certificate was not configured. Please install an updated Maharo Store.';
  static const msgIntegrity = 'File integrity check failed. Please try again.';
  static const msgInterrupted =
      'Download interrupted. Tap Install again to continue from where it stopped.';
  static const msgStalled =
      'Download stalled: no data received. Check your connection and tap Install '
      'again to continue from where it stopped.';
  static const msgTooLarge = 'Download is larger than expected. Aborted.';
  static const msgBadRange =
      'The server answered the resume request unexpectedly. Please try again.';

  // ── Storage helpers (single-APK policy) ──

  static Future<Directory> _defaultStagingDir() async {
    final support = await getApplicationSupportDirectory();
    return Directory('${support.path}/$stagingSubdir');
  }

  /// Where versions before SK-STORE-02 kept the APK (shared app-specific
  /// external storage). Only cleaned up now.
  static Future<Directory?> _defaultLegacyDir() => getExternalStorageDirectory();

  static Future<Directory?> _noLegacyDir() async => null;

  Future<Directory> _ensureStagingDir() async {
    final dir = await _stagingDirProvider();
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static String _baseName(String path) => path.split(RegExp(r'[\\/]')).last;

  static bool _isStagedArtifact(String name) =>
      name.endsWith('.apk') || name.endsWith('.bsdiff') || name.endsWith('.tmp');

  /// Delete every `.apk` / `.bsdiff` / `.tmp` file in the staging directory
  /// except the single APK slot (our resumable partial) and [keep].
  Future<void> _purgeStoredFiles({String? keep}) async {
    try {
      final dir = await _ensureStagingDir();
      final keepNorm = keep?.replaceAll('\\', '/').toLowerCase();
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final p = entity.path.replaceAll('\\', '/').toLowerCase();
        final name = _baseName(p);
        if (name == apkFileName) continue; // never purge the slot
        if (keepNorm != null && p == keepNorm) continue;
        if (_isStagedArtifact(name)) {
          await entity.delete();
          debugPrint('[DownloadManager] Purged stale file: ${entity.path}');
        }
      }
    } catch (e) {
      debugPrint('[DownloadManager] Purge failed (non-fatal): $e');
    }
  }

  /// Removes APK/patch files left in the old shared external location.
  Future<void> _purgeLegacyExternalFiles() async {
    Directory? legacy;
    try {
      legacy = await _legacyDirProvider();
    } catch (_) {
      return; // not available on this platform
    }
    if (legacy == null) return;
    try {
      if (!await legacy.exists()) return;
      await for (final entity in legacy.list()) {
        if (entity is! File) continue;
        if (_isStagedArtifact(_baseName(entity.path).toLowerCase())) {
          await entity.delete();
          debugPrint('[DownloadManager] Removed legacy external file: ${entity.path}');
        }
      }
    } catch (e) {
      debugPrint('[DownloadManager] Legacy cleanup failed (non-fatal): $e');
    }
  }

  /// Public cleanup for app start: keep at most the single latest APK
  /// (or its partial) and remove legacy leftovers. Never throws.
  Future<void> cleanOldApks() async {
    try {
      final stored = await _getStoredApkPath();
      if (stored == null) {
        await _clearMeta();
        await _clearVerified();
      }
      await _purgeStoredFiles(keep: stored);
      await _purgeLegacyExternalFiles();
    } catch (e) {
      debugPrint('[DownloadManager] Cleanup failed (non-fatal): $e');
    }
  }

  Future<String?> _getStoredApkPath() async {
    final path = '${(await _stagingDirProvider()).path}/$apkFileName';
    return await File(path).exists() ? path : null;
  }

  Future<void> _deleteQuietly(String path) async {
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// Drops the stored APK (partial or verified) and its records.
  Future<void> _discardStored() async {
    final path = '${(await _stagingDirProvider()).path}/$apkFileName';
    await _deleteQuietly(path);
    await _clearMeta();
    await _clearVerified();
  }

  // ── Resume metadata ──

  static Future<Map<String, dynamic>?> _readMeta() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_metaKey);
      if (raw == null || raw.isEmpty) return null;
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  static Future<void> _writeMeta({
    required String url,
    required String sha256,
    required int totalBytes,
    required String versionName,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_metaKey, jsonEncode({
      'url': url,
      'sha256': sha256,
      'totalBytes': totalBytes,
      'versionName': versionName,
      'at': DateTime.now().toIso8601String(),
    }));
  }

  static Future<void> _clearMeta() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_metaKey);
  }

  // ── Verified-APK record (what the slot holds after a passed SHA check) ──

  static Future<String?> _readVerifiedSha() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_verifiedKey);
      if (raw == null || raw.isEmpty) return null;
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return normalizeSha256(map['sha256'] as String?);
    } catch (_) {
      return null;
    }
  }

  static Future<void> _writeVerified({
    required String sha256,
    required String versionName,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_verifiedKey, jsonEncode({
      'sha256': sha256,
      'versionName': versionName,
      'at': DateTime.now().toIso8601String(),
    }));
  }

  static Future<void> _clearVerified() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_verifiedKey);
  }

  /// Partial APK on disk that can be continued (returns 0..1 progress, or
  /// null when there is nothing — or nothing valid — to resume).
  Future<double?> findResumableProgress({String? url, String? sha256}) async {
    final meta = await _readMeta();
    if (meta == null) return null;
    final String? path;
    final int size;
    try {
      path = await _getStoredApkPath();
      if (path == null) return null;
      size = await File(path).length();
    } catch (_) {
      return null; // storage unavailable: nothing to resume
    }
    final total = (meta['totalBytes'] as num?)?.toInt() ?? 0;
    if (size == 0 || total <= 0 || size >= total) return null;
    if (url != null && meta['url'] != url) return null;
    if (sha256 != null &&
        sha256.isNotEmpty &&
        normalizeSha256(meta['sha256'] as String?) != normalizeSha256(sha256)) {
      return null;
    }
    return size / total;
  }

  /// Whether this build may install at all (signer certificate pinned).
  Future<bool> installsAllowed() => _native.isSignerPinConfigured();

  // ── Full APK download / resume (one code path — Range does the rest) ──

  Future<void> downloadAndInstall({
    required String url,
    required String? expectedSha256,
    required String versionName,
    required Function(double progress, String status) onProgress,
    required Function(String filePath) onComplete,
    required Function(String error) onError,
    Function(double progress)? onPaused,
  }) async {
    _pausedByUser = false;
    _lastProgress = 0.0;

    // Server metadata is untrusted: check it BEFORE a single byte is
    // downloaded. SHA-256 verification is mandatory — never install without it.
    final sha = normalizeSha256(expectedSha256);
    if (sha == null) {
      onError(msgMissingHash);
      return;
    }
    if (parseHttpsUrl(url) == null) {
      onError(msgInsecureUrl);
      return;
    }
    if (!await _native.isSignerPinConfigured()) {
      onError(msgInstallsDisabled);
      return;
    }

    final cancelToken = CancelToken();
    _cancelToken = cancelToken;
    String? filePath;
    try {
      final dir = await _ensureStagingDir();
      filePath = '${dir.path}/$apkFileName';

      // Fresh version or stale partial? Drop the partial and start clean.
      final resumable = await findResumableProgress(url: url, sha256: sha);
      if (resumable == null) {
        await _deleteQuietly(filePath);
        await _clearMeta();
        await _clearVerified();
        await _purgeStoredFiles();
      }

      await _startForegroundService();

      await _rangeDownload(
        url: url,
        filePath: filePath,
        sha: sha,
        versionName: versionName,
        cancelToken: cancelToken,
        onProgress: onProgress,
      );

      onProgress(1.0, 'Verifying file integrity...');
      if (!await verifySha256(filePath, sha)) {
        await _deleteQuietly(filePath);
        await _clearMeta();
        onError(msgIntegrity);
        return;
      }
      await _clearMeta(); // bytes verified — no longer just a partial
      await _writeVerified(sha256: sha, versionName: versionName);

      await _installVerified(
        filePath,
        sha,
        onProgress: onProgress,
        onComplete: onComplete,
        onError: onError,
      );
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        if (_pausedByUser && onPaused != null) {
          onPaused(_lastProgress);
        } else {
          onError('Download cancelled');
        }
      } else if (e.type == DioExceptionType.receiveTimeout) {
        // Stalled stream: the partial stays for resume; `finally` stops the
        // foreground service.
        onError(msgStalled);
      } else if (e.type == DioExceptionType.badResponse &&
          e.response?.statusCode == 416) {
        if (filePath != null) await _discardPartial(filePath);
        onError(msgBadRange);
      } else {
        // Keep the partial — retry/resume will continue from it.
        onError('Download error: ${e.message ?? "Unknown error"}');
      }
    } on _DownloadFailure catch (e) {
      if (e.discardPartial && filePath != null) await _discardPartial(filePath);
      onError(e.message);
    } catch (e) {
      onError(e.toString());
    } finally {
      await _stopForegroundService();
    }
  }

  Future<void> _discardPartial(String filePath) async {
    await _deleteQuietly(filePath);
    await _clearMeta();
  }

  /// Stops the HTTP transfer (Dio would otherwise keep reading, and
  /// buffering, a body nobody consumes) and throws [failure].
  static Never _abort(CancelToken token, _DownloadFailure failure) {
    if (!token.isCancelled) token.cancel('aborted');
    throw failure;
  }

  /// Alias — with Range-based downloads, "resume" is just "download again":
  /// the engine picks up from the bytes already on disk.
  Future<void> resumeDownload({
    required String url,
    required String? expectedSha256,
    required String versionName,
    required Function(double progress, String status) onProgress,
    required Function(String filePath) onComplete,
    required Function(String error) onError,
    Function(double progress)? onPaused,
  }) =>
      downloadAndInstall(
        url: url,
        expectedSha256: expectedSha256,
        versionName: versionName,
        onProgress: onProgress,
        onComplete: onComplete,
        onError: onError,
        onPaused: onPaused,
      );

  /// Streams [url] into [filePath], continuing from the file's current size
  /// via `Range: bytes=<size>-`. A 206 must continue exactly at that offset;
  /// a 200 means the server ignored the Range and the partial is replaced.
  /// Throws [_DownloadFailure] for truncated, oversized or misaligned bodies.
  Future<void> _rangeDownload({
    required String url,
    required String filePath,
    required String sha,
    required String versionName,
    required CancelToken cancelToken,
    required Function(double progress, String status) onProgress,
  }) async {
    final file = File(filePath);
    var start = await file.exists() ? await file.length() : 0;

    final knownTotal = await _metaTotal();
    onProgress(
      start > 0 ? start / (knownTotal ?? start * 2) : 0.0,
      start > 0 ? 'Resuming from ${(start / 1048576).toStringAsFixed(1)} MB...' : 'Starting download...',
    );

    final response = await _dio.get<ResponseBody>(
      url,
      options: Options(
        responseType: ResponseType.stream,
        headers: start > 0 ? {'Range': 'bytes=$start-'} : null,
        receiveTimeout: _idleTimeout,
      ),
      cancelToken: cancelToken,
    );
    final body = response.data;
    final status = response.statusCode ?? 0;
    if (body == null) {
      _abort(cancelToken, const _DownloadFailure('Download error: empty response', discardPartial: false));
    }

    int? total;
    if (start > 0 && status == 206) {
      final m = RegExp(r'^bytes\s+(\d+)-(\d+)/(\d+)$')
          .firstMatch((response.headers.value('content-range') ?? '').trim());
      final first = m == null ? null : int.tryParse(m.group(1)!);
      total = m == null ? null : int.tryParse(m.group(3)!);
      if (first != start || total == null) {
        _abort(cancelToken, const _DownloadFailure(msgBadRange, discardPartial: true));
      }
    } else if (status == 200) {
      // Full body: either a fresh download, or the server ignored the Range
      // while we hold partial bytes — that partial is replaced, never appended to.
      start = 0;
      final len = int.tryParse(response.headers.value('content-length') ?? '');
      if (len != null && len >= 0) total = len;
    } else {
      _abort(
          cancelToken,
          _DownloadFailure('Download error: unexpected HTTP $status',
              discardPartial: start > 0));
    }

    if (total != null && total > maxApkBytes) {
      _abort(cancelToken, const _DownloadFailure(msgTooLarge, discardPartial: true));
    }
    if (total != null && total > 0) {
      await _writeMeta(url: url, sha256: sha, totalBytes: total, versionName: versionName);
    }

    final raf = await file.open(mode: start == 0 ? FileMode.write : FileMode.append);
    var received = 0;
    try {
      await for (final chunk in body.stream) {
        received += chunk.length;
        final done = start + received;
        if ((total != null && done > total) || done > maxApkBytes) {
          _abort(cancelToken, const _DownloadFailure(msgTooLarge, discardPartial: true));
        }
        await raf.writeFrom(chunk);
        if (total != null && total > 0) {
          final downloadedMB = (done / 1048576).toStringAsFixed(1);
          final totalMB = (total / 1048576).toStringAsFixed(1);
          _lastProgress = done / total;
          onProgress(_lastProgress, 'Downloading $downloadedMB / $totalMB MB');
        }
      }
    } finally {
      await raf.close();
    }

    // The stream ended before the announced size: keep the partial so the
    // next attempt resumes with a Range request.
    if (total != null && start + received < total) {
      throw const _DownloadFailure(msgInterrupted, discardPartial: false);
    }
  }

  Future<int?> _metaTotal() async {
    final meta = await _readMeta();
    return (meta?['totalBytes'] as num?)?.toInt();
  }

  /// Plain (non-resumable) download used for patch files: idle timeout,
  /// size cap, and the announced length must be met exactly.
  Future<void> _downloadToFile(
    String url,
    String path, {
    required int maxBytes,
    required CancelToken cancelToken,
    void Function(int received, int? total)? onBytes,
  }) async {
    final response = await _dio.get<ResponseBody>(
      url,
      options: Options(responseType: ResponseType.stream, receiveTimeout: _idleTimeout),
      cancelToken: cancelToken,
    );
    final body = response.data;
    if (response.statusCode != 200 || body == null) {
      _abort(
          cancelToken,
          _DownloadFailure('Patch download failed (HTTP ${response.statusCode})',
              discardPartial: true));
    }
    final total = int.tryParse(response.headers.value('content-length') ?? '');
    if (total != null && total > maxBytes) {
      _abort(cancelToken, const _DownloadFailure('Patch is larger than allowed', discardPartial: true));
    }
    final raf = await File(path).open(mode: FileMode.write);
    var received = 0;
    try {
      await for (final chunk in body.stream) {
        received += chunk.length;
        if (received > maxBytes) {
          _abort(cancelToken, const _DownloadFailure('Patch is larger than allowed', discardPartial: true));
        }
        await raf.writeFrom(chunk);
        onBytes?.call(received, total);
      }
    } finally {
      await raf.close();
    }
    if (total != null && received != total) {
      throw const _DownloadFailure('Patch download was interrupted', discardPartial: true);
    }
  }

  // ── Delta patch flow ──

  Future<void> downloadAndApplyPatch({
    required String patchUrl,
    required String patchSha256,
    required String fullApkSha256,
    required String packageName,
    required String versionName,
    required Function(double progress, String status) onProgress,
    required Function(String filePath) onComplete,
    required Function(String error) onError,
    required String fullDownloadUrl,
    required int fullFileSizeBytes,
  }) async {
    Future<void> fallbackFullDownload(String status) async {
      onProgress(0, status);
      await downloadAndInstall(
        url: fullDownloadUrl,
        expectedSha256: fullApkSha256,
        versionName: versionName,
        onProgress: onProgress,
        onComplete: onComplete,
        onError: onError,
      );
    }

    final fullSha = normalizeSha256(fullApkSha256);
    if (fullSha == null) {
      onError(msgMissingHash);
      return;
    }
    final patchSha = normalizeSha256(patchSha256);
    if (patchSha == null || parseHttpsUrl(patchUrl) == null || packageName != targetPackage) {
      await fallbackFullDownload('Falling back to full download...');
      return;
    }
    if (!await _native.isSignerPinConfigured()) {
      onError(msgInstallsDisabled);
      return;
    }

    final cancelToken = CancelToken();
    _cancelToken = cancelToken;
    String? patchPath;
    String? tmpApkPath;
    try {
      await _startForegroundService();

      final dir = await _ensureStagingDir();
      patchPath = '${dir.path}/$patchFileName';
      tmpApkPath = '${dir.path}/$patchTmpFileName';
      final newApkPath = '${dir.path}/$apkFileName';

      // 1. Resolve the base APK — prefer our pristine single stored copy, but
      //    only when it is a complete verified file (never a partial).
      onProgress(0, 'Preparing delta update...');
      final stored = await _getStoredApkPath();
      String? oldApkPath;
      if (stored != null && await _readVerifiedSha() != null && await File(stored).length() > 0) {
        oldApkPath = stored;
      } else {
        // Fall back to the system-installed APK
        oldApkPath = await _native.getInstalledApkPath(packageName);
      }

      if (oldApkPath == null || oldApkPath.isEmpty) {
        await fallbackFullDownload('Falling back to full download...');
        return;
      }

      final baseIsStoredCopy = oldApkPath == stored;
      await _purgeStoredFiles(keep: baseIsStoredCopy ? oldApkPath : null);

      // 2. Download the patch file (idle timeout, size cap)
      onProgress(0.05, 'Downloading patch...');
      // A patch much larger than the APK it rebuilds is refused (1 MiB slack
      // covers bzip2 overhead on tiny files).
      final maxPatch = fullFileSizeBytes > 0
          ? math.min(fullFileSizeBytes + 1024 * 1024, maxApkBytes)
          : maxApkBytes;
      await _downloadToFile(
        patchUrl,
        patchPath,
        maxBytes: maxPatch,
        cancelToken: cancelToken,
        onBytes: (received, total) {
          if (total != null && total > 0) {
            final progress = 0.05 + (received / total) * 0.45;
            onProgress(progress, 'Downloading patch ${(received / 1048576).toStringAsFixed(1)} MB');
          }
        },
      );

      // 3. Verify patch integrity
      onProgress(0.50, 'Verifying patch...');
      if (!await verifySha256(patchPath, patchSha)) {
        await _deleteQuietly(patchPath);
        await fallbackFullDownload('Patch verification failed, downloading full APK...');
        return;
      }

      // 4. Apply the patch (background isolate, bounded memory)
      onProgress(0.55, 'Applying patch...');
      final applied = await _applyPatch(
        oldFile: File(oldApkPath),
        patchFile: File(patchPath),
        newFile: File(tmpApkPath),
        expectedNewSize: fullFileSizeBytes > 0 ? fullFileSizeBytes : null,
      );
      await _deleteQuietly(patchPath);
      if (!applied) {
        await _deleteQuietly(tmpApkPath);
        await fallbackFullDownload('Patch failed, downloading full APK...');
        return;
      }

      // 5. Verify the reconstructed APK before it replaces anything
      onProgress(0.90, 'Verifying update...');
      if (!await verifySha256(tmpApkPath, fullSha)) {
        await _deleteQuietly(tmpApkPath);
        await fallbackFullDownload('Verification failed, downloading full APK...');
        return;
      }
      await _clearVerified();
      await File(tmpApkPath).rename(newApkPath);
      await _clearMeta();
      await _writeVerified(sha256: fullSha, versionName: versionName);

      // 6. Install
      await _installVerified(
        newApkPath,
        fullSha,
        onProgress: onProgress,
        onComplete: onComplete,
        onError: onError,
      );
    } on DioException catch (e) {
      if (patchPath != null) await _deleteQuietly(patchPath);
      if (e.type == DioExceptionType.cancel) {
        onError('Download cancelled');
      } else {
        await fallbackFullDownload('Error, downloading full APK...');
      }
    } on _DownloadFailure {
      if (patchPath != null) await _deleteQuietly(patchPath);
      await fallbackFullDownload('Patch download failed, downloading full APK...');
    } catch (e) {
      if (tmpApkPath != null) await _deleteQuietly(tmpApkPath);
      onError(e.toString());
    } finally {
      await _stopForegroundService();
    }
  }

  // ── Install helpers ──

  Future<void> _installVerified(
    String filePath,
    String sha, {
    required Function(double progress, String status) onProgress,
    required Function(String filePath) onComplete,
    required Function(String error) onError,
  }) async {
    onProgress(1.0, 'Opening installer...');
    onComplete(filePath);

    if (_installDelay > Duration.zero) await Future.delayed(_installDelay);
    await _recordInstallBaseline();

    // The native side hashes the bytes again while streaming them into the
    // PackageInstaller session and checks package name + pinned signer.
    final result = await _native.installPackage(filePath, sha);
    await _handleInstallResult(result, onError);
  }

  /// Install failures that prove the stored file itself is unusable.
  static const _artifactRejections = {
    'sha_mismatch',
    'signer_mismatch',
    'package_mismatch',
    'apk_unreadable',
  };

  Future<void> _handleInstallResult(
    Map<String, dynamic> result,
    Function(String error) onError,
  ) async {
    final ok = result['success'] == true;
    final code = '${result['message'] ?? ''}';
    if (ok) {
      installEvents.add('installed');
    } else if (code == 'pending_user_action_background') {
      installEvents.add('needs_user');
    } else {
      if (_artifactRejections.contains(code)) await _discardStored();
      onError(describeInstallFailure(code));
    }
  }

  /// User-facing text for a native install result code.
  static String describeInstallFailure(String code, {String? fallback}) {
    return switch (code) {
      'signer_pin_missing' => msgInstallsDisabled,
      'signer_mismatch' =>
        'Install blocked: the downloaded app is not signed with the Maharo release key.',
      'package_mismatch' => 'Install blocked: the downloaded file is not the Maharo app.',
      'sha_mismatch' => msgIntegrity,
      'bad_sha256' => msgMissingHash,
      'apk_unreadable' => 'Install blocked: the downloaded file is not a valid Android app.',
      'install_unverified' =>
        'The installer reported success, but Maharo was not updated. Please try again.',
      'confirm_untrusted' =>
        'Install blocked: the confirmation screen did not come from the system installer.',
      'install_in_progress' => 'Another installation is already in progress.',
      'no_stored_apk' => 'The downloaded file is no longer available. Start the download again.',
      'stored_apk_outdated' => 'A newer version is available. Start the download again.',
      _ => fallback ?? 'Install failed: $code',
    };
  }

  Future<void> _recordInstallBaseline() async {
    installBaselineTime = await _native.getLastUpdateTime(targetPackage);
  }

  /// Re-opens the stored APK in the system installer (used when a download
  /// finished while the store was backgrounded). The file is re-verified
  /// against the SHA-256 recorded when it passed verification, and against
  /// [currentSha256] (the release on screen) when given; a mismatch deletes
  /// it and nothing is installed.
  Future<Map<String, dynamic>> retryInstallFromStored({String? currentSha256}) async {
    final path = await _getStoredApkPath();
    final verifiedSha = await _readVerifiedSha();
    if (path == null || verifiedSha == null) {
      return {'success': false, 'message': 'no_stored_apk'};
    }
    final current = normalizeSha256(currentSha256);
    if (current != null && current != verifiedSha) {
      await _discardStored();
      return {'success': false, 'message': 'stored_apk_outdated'};
    }
    if (!await _native.isSignerPinConfigured()) {
      return {'success': false, 'message': 'signer_pin_missing'};
    }
    if (!await verifySha256(path, verifiedSha)) {
      await _discardStored();
      return {'success': false, 'message': 'sha_mismatch'};
    }
    await _recordInstallBaseline();
    final result = await _native.installPackage(path, verifiedSha);
    if (result['success'] != true &&
        _artifactRejections.contains('${result['message'] ?? ''}')) {
      await _discardStored();
    }
    return result;
  }

  // ── Foreground service (keeps downloading while app is backgrounded) ──

  Future<void> _startForegroundService() async {
    if (_serviceRunning) return;
    _serviceRunning = true;
    await _native.startDownloadService();
  }

  Future<void> _stopForegroundService() async {
    if (!_serviceRunning) return;
    _serviceRunning = false;
    try {
      await _native.stopDownloadService();
    } catch (_) {}
  }

  // ── Misc ──

  /// User tapped Pause: stop transferring but keep the partial bytes on
  /// disk so the existing "Paused at X% / Resume" flow can continue later.
  void pauseDownload() {
    _pausedByUser = true;
    _cancelToken?.cancel();
    _stopForegroundService();
  }

  void cancelDownload() {
    _cancelToken?.cancel();
    _cancelToken = null;
    _stopForegroundService();
  }

  /// True when the file at [filePath] hashes to [expectedSha256] (64 hex).
  @visibleForTesting
  static Future<bool> verifySha256(String filePath, String expectedSha256) async {
    final expected = normalizeSha256(expectedSha256);
    if (expected == null) return false;
    final file = File(filePath);
    if (!await file.exists()) return false;
    final digest = await crypto.sha256.bind(file.openRead()).first;
    return digest.toString() == expected;
  }
}

/// A download that cannot continue as-is. [discardPartial] says whether the
/// bytes on disk are unusable (otherwise they stay for a Range resume).
class _DownloadFailure implements Exception {
  const _DownloadFailure(this.message, {required this.discardPartial});

  final String message;
  final bool discardPartial;

  @override
  String toString() => message;
}
