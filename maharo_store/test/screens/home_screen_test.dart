// HomeScreen shows load failures as retryable errors (SK-STORE-05g) and says
// up front when this build cannot install anything because no signer
// certificate is pinned (SK-STORE-02, fail closed).

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maharo_store/core/download_manager.dart';
import 'package:maharo_store/core/package_service.dart';
import 'package:maharo_store/models/store_app.dart';
import 'package:maharo_store/models/store_version.dart';
import 'package:maharo_store/providers/download_provider.dart';
import 'package:maharo_store/providers/installed_provider.dart';
import 'package:maharo_store/providers/store_provider.dart';
import 'package:maharo_store/screens/home_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Native implements StoreNative {
  _Native(this.pinned);
  final bool pinned;

  @override
  Future<Map<String, dynamic>> installPackage(String apkPath, String sha256) async =>
      {'success': false, 'message': 'not in tests'};
  @override
  Future<bool> isSignerPinConfigured() async => pinned;
  @override
  Future<int> getLastUpdateTime(String packageName) async => 0;
  @override
  Future<String?> getInstalledApkPath(String packageName) async => null;
  @override
  Future<void> startDownloadService() async {}
  @override
  Future<void> stopDownloadService() async {}
}

StoreVersion _version() => StoreVersion(
      id: 'v20',
      versionName: '2.0.0',
      versionCode: 20,
      changelog: '',
      changelogEn: '',
      downloadUrl: 'https://cdn.maharoapp.com/apk/maharo-2.0.0.apk',
      fileSizeBytes: 50 * 1024 * 1024,
      sha256: 'adfe56595acdd3d42e6df0f0d29fa7363feb22ee1539e3fd3c3faacbfd8f0c28',
      createdAt: DateTime(2026, 10, 20),
    );

void main() {
  late Directory staging;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    staging = Directory.systemTemp.createTempSync('home_screen_test_');
  });

  tearDown(() => staging.deleteSync(recursive: true));

  Widget app({
    required Future<StoreVersion?> Function() latest,
    Future<StoreApp?> Function()? appInfo,
    bool pinned = true,
  }) {
    final manager = DownloadManager.forTesting(
      dio: Dio(),
      stagingDir: () async => staging,
      native: _Native(pinned),
    );
    return ProviderScope(
      overrides: [
        downloadManagerProvider.overrideWithValue(manager),
        appInfoProvider.overrideWith((ref, id) =>
            appInfo?.call() ??
            Future.value(StoreApp(id: 'a1', name: 'Maharo', packageName: id, description: ''))),
        latestVersionProvider.overrideWith((ref, id) => latest()),
        versionsProvider.overrideWith((ref, id) async => <StoreVersion>[]),
        installedVersionProvider.overrideWith((ref, id) async => null),
      ],
      child: const MaterialApp(home: HomeScreen()),
    );
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
    // Let the 1.2 s resume check in initState run.
    await tester.pump(const Duration(seconds: 2));
  }

  testWidgets('a latest-version load failure is shown with Retry, not as "no version"',
      (tester) async {
    var calls = 0;
    await tester.pumpWidget(app(latest: () async {
      calls++;
      if (calls == 1) throw Exception('network down');
      return _version();
    }));
    await settle(tester);

    expect(find.text('Could not load the latest version.'), findsOneWidget);
    expect(find.text('No version available'), findsNothing);

    await tester.tap(find.text('Retry'));
    await settle(tester);

    expect(calls, 2);
    expect(find.text('Install'), findsOneWidget);
    expect(find.text('Could not load the latest version.'), findsNothing);
  });

  testWidgets('a store listing failure shows the retryable "No connection" view',
      (tester) async {
    await tester.pumpWidget(app(
      latest: () async => _version(),
      appInfo: () => Future<StoreApp?>.error(Exception('offline')),
    ));
    await settle(tester);
    expect(find.text('No connection'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('without a pinned signer certificate the screen says installs are disabled',
      (tester) async {
    await tester.pumpWidget(app(latest: () async => _version(), pinned: false));
    await settle(tester);
    expect(find.text('Installs are disabled in this Store build'), findsOneWidget);
  });

  testWidgets('with a pinned certificate no such banner is shown', (tester) async {
    await tester.pumpWidget(app(latest: () async => _version()));
    await settle(tester);
    expect(find.text('Installs are disabled in this Store build'), findsNothing);
    expect(find.text('Install'), findsOneWidget);
  });
}
