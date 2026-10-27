// Store providers expose load errors (AsyncError) instead of turning them
// into null / [] — the UI then offers Retry rather than "nothing available".

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maharo_store/core/api_client.dart';
import 'package:maharo_store/providers/store_provider.dart';

class FakeApi implements HttpClientAdapter {
  final routes = <String, ResponseBody Function()>{};

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final route = routes[options.uri.path];
    if (route == null) throw const SocketExceptionLike();
    return route();
  }

  @override
  void close({bool force = false}) {}
}

class SocketExceptionLike implements Exception {
  const SocketExceptionLike();
}

ResponseBody json(Object body, {int status = 200}) => ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        'content-type': ['application/json'],
      },
    );

const sha = 'adfe56595acdd3d42e6df0f0d29fa7363feb22ee1539e3fd3c3faacbfd8f0c28';

Map<String, Object> version(int code) => {
      'id': 'v$code',
      'versionName': '2.0.$code',
      'versionCode': code,
      'downloadUrl': 'https://cdn.maharoapp.com/apk/$code.apk',
      'fileSizeBytes': 1000,
      'sha256': sha,
      'createdAt': '2026-10-20T00:00:00.000Z',
    };

void main() {
  late FakeApi api;
  late ProviderContainer container;

  setUp(() {
    api = FakeApi();
    container = ProviderContainer(overrides: [
      apiClientProvider.overrideWithValue(ApiClient(
        dio: Dio(BaseOptions(baseUrl: 'https://api.test'))..httpClientAdapter = api,
      )),
    ]);
  });

  tearDown(() => container.dispose());

  group('appInfoProvider', () {
    test('returns the listed app, or null when the store does not list it', () async {
      api.routes['/store/apps'] = () => json([
            {'id': 'a1', 'name': 'Maharo', 'packageName': 'app.maharo', 'description': ''},
          ]);
      expect((await container.read(appInfoProvider('app.maharo').future))!.id, 'a1');
      expect(await container.read(appInfoProvider('app.other').future), isNull);
    });

    test('network and server errors surface as errors', () async {
      api.routes['/store/apps'] = () => json({'message': 'boom'}, status: 500);
      await expectLater(container.read(appInfoProvider('app.maharo').future), throwsA(anything));
    });
  });

  group('latestVersionProvider', () {
    test('404 means "no version published" (null)', () async {
      api.routes['/store/apps/app.maharo/latest'] =
          () => json({'message': 'No versions available'}, status: 404);
      expect(await container.read(latestVersionProvider('app.maharo').future), isNull);
    });

    test('other failures are errors, not "no version"', () async {
      api.routes['/store/apps/app.maharo/latest'] = () => json({'message': 'down'}, status: 503);
      await expectLater(
          container.read(latestVersionProvider('app.maharo').future), throwsA(anything));
    });

    test('unreachable server is an error', () async {
      await expectLater(
          container.read(latestVersionProvider('app.maharo').future), throwsA(anything));
    });

    test('parses the latest version', () async {
      api.routes['/store/apps/app.maharo/latest'] = () => json(version(20));
      final v = await container.read(latestVersionProvider('app.maharo').future);
      expect(v!.versionCode, 20);
      expect(v.sha256, sha);
    });
  });

  group('versionsProvider', () {
    test('errors are not turned into an empty list', () async {
      await expectLater(
          container.read(versionsProvider('app.maharo').future), throwsA(anything));
    });

    test('parses the list', () async {
      api.routes['/store/apps/app.maharo/versions'] = () => json([version(20), version(19)]);
      final list = await container.read(versionsProvider('app.maharo').future);
      expect(list.map((v) => v.versionCode), [20, 19]);
    });
  });

  group('patchProvider', () {
    const args = (appId: 'app.maharo', fromVersionCode: 19);

    test('null when the API has no patch', () async {
      api.routes['/store/apps/app.maharo/patch'] = () => json({'patch': null});
      expect(await container.read(patchProvider(args).future), isNull);
    });

    test('parses a patch into StorePatch', () async {
      api.routes['/store/apps/app.maharo/patch'] = () => json({
            'patch': {
              'patchUrl': 'https://cdn.maharoapp.com/apk/19-20.bsdiff',
              'patchSizeBytes': 100,
              'patchSha256': sha,
              'fullApkSha256': sha,
              'fromVersionCode': 19,
              'toVersionCode': 20,
            },
            'fullDownload': version(20),
          });
      final p = await container.read(patchProvider(args).future);
      expect(p!.fromVersionCode, 19);
      expect(p.toVersionCode, 20);
    });

    test('malformed payloads and failures are errors (caller falls back to full)',
        () async {
      api.routes['/store/apps/app.maharo/patch'] = () => json({
            'patch': {'patchUrl': 42},
          });
      await expectLater(container.read(patchProvider(args).future), throwsA(anything));
    });
  });
}
