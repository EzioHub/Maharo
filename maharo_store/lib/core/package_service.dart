import 'package:flutter/services.dart';

class PackageService {
  static const _channel = MethodChannel('app.maharo.store/packages');

  /// Returns installed version info or null if not installed
  static Future<InstalledAppInfo?> getInstalledVersion(String packageName) async {
    try {
      final result = await _channel.invokeMethod('getInstalledVersion', {'packageName': packageName});
      if (result == null) return null;
      final map = Map<String, dynamic>.from(result);
      return InstalledAppInfo(
        versionName: map['versionName'] as String? ?? '',
        versionCode: (map['versionCode'] as num?)?.toInt() ?? 0,
      );
    } catch (e) {
      return null;
    }
  }

  /// Launch an installed app
  static Future<bool> openApp(String packageName) async {
    try {
      final result = await _channel.invokeMethod('openApp', {'packageName': packageName});
      return result == true;
    } catch (e) {
      return false;
    }
  }

  /// Epoch millis of the package's last install/update, 0 when not installed.
  /// Used to detect whether a system-installer session actually installed
  /// anything — reliable even when old/new builds share a versionCode.
  static Future<int> getLastUpdateTime(String packageName) async {
    try {
      final result = await _channel.invokeMethod('getLastUpdateTime', {'packageName': packageName});
      return (result as num?)?.toInt() ?? 0;
    } catch (e) {
      return 0;
    }
  }

  /// Open Android's uninstall confirmation dialog for [packageName]. The user
  /// confirms in the system dialog — used to remove an old differently-signed
  /// build that blocks updates ("package conflicts with an existing package").
  static Future<bool> requestUninstall(String packageName) async {
    try {
      final result = await _channel.invokeMethod('requestUninstall', {'packageName': packageName});
      return result == true;
    } catch (e) {
      return false;
    }
  }

  /// Opens the system App Info settings page for [packageName] — manual
  /// fallback when an OEM ROM blocks the uninstall dialog.
  static Future<bool> openAppDetails(String packageName) async {
    try {
      final result = await _channel.invokeMethod('openAppDetails', {'packageName': packageName});
      return result == true;
    } catch (e) {
      return false;
    }
  }

  /// Installs [apkPath] through a native PackageInstaller session with
  /// update-ownership. First install: user confirms once in the system
  /// dialog. Updates of a store-owned package: installed silently.
  ///
  /// Native side refuses unless the file sits in the store's private staging
  /// directory, is `app.maharo` signed by a pinned certificate, and the bytes
  /// streamed into the session hash to [sha256]. Failures come back as
  /// `{'success': false, 'message': <code>}`.
  static Future<Map<String, dynamic>> installPackage(String apkPath, String sha256) async {
    try {
      final result = await _channel.invokeMethod('installPackage', {'apkPath': apkPath, 'sha256': sha256});
      return Map<String, dynamic>.from(result as Map);
    } catch (e) {
      return {'success': false, 'message': e.toString()};
    }
  }

  /// Whether this build carries a pinned signer certificate for `app.maharo`.
  /// Without one the native installer refuses every install (fail closed);
  /// any channel error also counts as "not configured".
  static Future<bool> isSignerPinConfigured() async {
    try {
      final result = await _channel.invokeMethod('getInstallPolicy');
      return result is Map && result['signerPinConfigured'] == true;
    } catch (e) {
      return false;
    }
  }

  /// Path of the installed APK of [packageName] (delta-patch base), or null.
  static Future<String?> getInstalledApkPath(String packageName) async {
    try {
      return await _channel.invokeMethod<String>('getInstalledApkPath', {'packageName': packageName});
    } catch (e) {
      return null;
    }
  }

  /// Starts/stops the foreground service that keeps downloads alive while
  /// the store is backgrounded. Best effort: a failure never aborts a
  /// download.
  static Future<void> startDownloadService() async {
    try {
      await _channel.invokeMethod('startDownloadService');
    } catch (_) {}
  }

  static Future<void> stopDownloadService() async {
    try {
      await _channel.invokeMethod('stopDownloadService');
    } catch (_) {}
  }
}

class InstalledAppInfo {
  final String versionName;
  final int versionCode;

  InstalledAppInfo({required this.versionName, required this.versionCode});
}

/// Native operations the download engine depends on. The default
/// implementation talks to `MainActivity` over the platform channel; tests
/// inject a fake.
abstract class StoreNative {
  Future<Map<String, dynamic>> installPackage(String apkPath, String sha256);
  Future<bool> isSignerPinConfigured();
  Future<int> getLastUpdateTime(String packageName);
  Future<String?> getInstalledApkPath(String packageName);
  Future<void> startDownloadService();
  Future<void> stopDownloadService();
}

class ChannelStoreNative implements StoreNative {
  const ChannelStoreNative();

  @override
  Future<Map<String, dynamic>> installPackage(String apkPath, String sha256) =>
      PackageService.installPackage(apkPath, sha256);

  @override
  Future<bool> isSignerPinConfigured() => PackageService.isSignerPinConfigured();

  @override
  Future<int> getLastUpdateTime(String packageName) =>
      PackageService.getLastUpdateTime(packageName);

  @override
  Future<String?> getInstalledApkPath(String packageName) =>
      PackageService.getInstalledApkPath(packageName);

  @override
  Future<void> startDownloadService() => PackageService.startDownloadService();

  @override
  Future<void> stopDownloadService() => PackageService.stopDownloadService();
}
