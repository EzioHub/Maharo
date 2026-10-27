// DownloadManager decision logic: the SHA gate, metadata checks before any
// download, HTTP Range resume (206 vs 200, truncation, misaligned ranges),
// pause/cancel, the stall (idle) timeout, the single-APK policy, re-verified
// retries and the delta-patch flow with its full-download fallback.
//
// The HTTP client, the staging directory and the native channel are fakes
// injected through DownloadManager.forTesting; nothing touches the network,
// the platform channel or real app storage.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maharo_store/core/download_manager.dart';
import 'package:maharo_store/core/package_service.dart';
import 'package:maharo_store/providers/download_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const apkUrl = 'https://cdn.maharoapp.com/apk/maharo-2.0.0.apk';
const patchUrl = 'https://cdn.maharoapp.com/apk/maharo-1.9-2.0.bsdiff';

String sha256Hex(List<int> bytes) => crypto.sha256.convert(bytes).toString();

class FakeNative implements StoreNative {
  bool pinConfigured = true;
  Map<String, dynamic> installResult = {'success': true, 'message': ''};
  final installCalls = <(String, String)>[];
  int startCalls = 0;
  int stopCalls = 0;
  String? installedApkPath;

  @override
  Future<Map<String, dynamic>> installPackage(String apkPath, String sha256) async {
    installCalls.add((apkPath, sha256));
    return installResult;
  }

  @override
  Future<bool> isSignerPinConfigured() async => pinConfigured;

  @override
  Future<int> getLastUpdateTime(String packageName) async => 0;

  @override
  Future<String?> getInstalledApkPath(String packageName) async => installedApkPath;

  @override
  Future<void> startDownloadService() async => startCalls++;

  @override
  Future<void> stopDownloadService() async => stopCalls++;
}

typedef Handler = FutureOr<ResponseBody> Function(RequestOptions options);

class FakeAdapter implements HttpClientAdapter {
  Handler handler = (o) => throw StateError('unexpected request ${o.uri}');
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

Stream<Uint8List> chunked(List<int> bytes, {int size = 1000}) async* {
  for (var i = 0; i < bytes.length; i += size) {
    yield Uint8List.fromList(bytes.sublist(i, i + size > bytes.length ? bytes.length : i + size));
  }
}

Stream<Uint8List> paced(List<int> bytes, {int size = 500}) async* {
  for (var i = 0; i < bytes.length; i += size) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
    yield Uint8List.fromList(bytes.sublist(i, i + size > bytes.length ? bytes.length : i + size));
  }
}

ResponseBody ok200(List<int> bytes, {int? contentLength, Stream<Uint8List>? stream}) =>
    ResponseBody(stream ?? chunked(bytes), 200, headers: {
      'content-length': ['${contentLength ?? bytes.length}'],
    });

/// A server that honours `Range: bytes=N-` with a 206.
ResponseBody rangeServer(RequestOptions o, List<int> bytes) {
  final range = o.headers['Range'] as String?;
  if (range == null) return ok200(bytes);
  final start = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
  final rest = bytes.sublist(start);
  return ResponseBody(chunked(rest), 206, headers: {
    'content-range': ['bytes $start-${bytes.length - 1}/${bytes.length}'],
    'content-length': ['${rest.length}'],
  });
}

class Run {
  final progress = <double>[];
  final errors = <String>[];
  final completed = <String>[];
  final paused = <double>[];
  final events = <String>[];
}

void main() {
  late Directory tmp;
  late Directory staging;
  late FakeNative native;
  late FakeAdapter adapter;
  late DownloadManager dm;
  late List<int> apk;
  late String apkSha;
  late String slot;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('store_dm_test_');
    staging = Directory('${tmp.path}/apk');
    native = FakeNative();
    adapter = FakeAdapter();
    dm = DownloadManager.forTesting(
      dio: Dio()..httpClientAdapter = adapter,
      stagingDir: () async => staging,
      native: native,
      idleTimeout: const Duration(milliseconds: 300),
    );
    apk = List<int>.generate(10000, (i) => (i * 31 + 7) & 0xFF);
    apkSha = sha256Hex(apk);
    slot = '${staging.path}/${DownloadManager.apkFileName}';
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  Future<Run> download({
    String url = apkUrl,
    required String? sha,
    void Function(double p)? onProgress,
  }) async {
    final run = Run();
    final sub = dm.installEvents.stream.listen(run.events.add);
    await dm.downloadAndInstall(
      url: url,
      expectedSha256: sha,
      versionName: '2.0.0',
      onProgress: (p, s) {
        run.progress.add(p);
        onProgress?.call(p);
      },
      onComplete: run.completed.add,
      onError: run.errors.add,
      onPaused: run.paused.add,
    );
    await Future<void>.delayed(Duration.zero); // deliver broadcast events
    await sub.cancel();
    return run;
  }

  void expectNoInstallAndNoSuccess(Run run) {
    expect(native.installCalls, isEmpty, reason: 'install must never be called');
    expect(run.events, isNot(contains('installed')));
    expect(run.completed, isEmpty, reason: 'no "Opening installer" step');
  }

  group('SHA gate', () {
    test('mismatching SHA-256: never installs, never reports success, deletes the file',
        () async {
      adapter.handler = (o) => ok200(apk);
      final run = await download(sha: sha256Hex([1, 2, 3]));
      expectNoInstallAndNoSuccess(run);
      expect(run.errors, [DownloadManager.msgIntegrity]);
      expect(File(slot).existsSync(), isFalse);
      expect(native.stopCalls, greaterThanOrEqualTo(1), reason: 'service stopped');
    });

    test('missing or malformed hash is refused before any request', () async {
      for (final bad in <String?>[null, '', '   ', 'abc', 'g' * 64, '${apkSha}0']) {
        final run = await download(sha: bad);
        expectNoInstallAndNoSuccess(run);
        expect(run.errors, [DownloadManager.msgMissingHash], reason: 'hash: $bad');
      }
      expect(adapter.requests, isEmpty, reason: 'nothing downloaded');
      expect(native.startCalls, 0);
    });

    test('a non-https download URL is refused before any request', () async {
      for (final url in [
        'http://cdn.maharoapp.com/a.apk',
        'file:///sdcard/a.apk',
        '/relative.apk',
      ]) {
        final run = await download(url: url, sha: apkSha);
        expectNoInstallAndNoSuccess(run);
        expect(run.errors, [DownloadManager.msgInsecureUrl]);
      }
      expect(adapter.requests, isEmpty);
    });

    test('without a pinned signer certificate nothing is downloaded (fail closed)',
        () async {
      native.pinConfigured = false;
      final run = await download(sha: apkSha);
      expectNoInstallAndNoSuccess(run);
      expect(run.errors, [DownloadManager.msgInstallsDisabled]);
      expect(adapter.requests, isEmpty);
    });

    test('verified APK is installed with its hash, success reported once', () async {
      adapter.handler = (o) => ok200(apk);
      final run = await download(sha: apkSha.toUpperCase());
      expect(run.errors, isEmpty);
      expect(native.installCalls, [(slot, apkSha)], reason: 'lower-cased hash passed on');
      expect(run.completed, [slot]);
      expect(run.events, ['installed']);
      expect(File(slot).readAsBytesSync(), apk, reason: 'kept as delta base');
      expect(native.startCalls, 1);
      expect(native.stopCalls, 1);
    });

    test('native rejections surface as errors, never as success', () async {
      for (final code in ['sha_mismatch', 'signer_mismatch', 'package_mismatch']) {
        native.installResult = {'success': false, 'message': code};
        adapter.handler = (o) => ok200(apk);
        final run = await download(sha: apkSha);
        expect(run.events, isEmpty, reason: code);
        expect(run.errors, [DownloadManager.describeInstallFailure(code)]);
        expect(File(slot).existsSync(), isFalse,
            reason: 'a rejected artifact is deleted ($code)');
      }
      native.installResult = {'success': false, 'message': 'signer_pin_missing'};
      final run = await download(sha: apkSha);
      expect(run.events, isEmpty);
      expect(run.errors, [DownloadManager.msgInstallsDisabled]);
    });

    test('install pending in the background is reported as needs_user, not success',
        () async {
      native.installResult = {'success': false, 'message': 'pending_user_action_background'};
      adapter.handler = (o) => ok200(apk);
      final run = await download(sha: apkSha);
      expect(run.events, ['needs_user']);
      expect(run.errors, isEmpty);
    });
  });

  group('Range resume', () {
    /// First attempt: the stream ends at [cut] bytes although 10000 were announced.
    Future<void> interruptAt(int cut) async {
      adapter.handler = (o) => ok200(apk.sublist(0, cut), contentLength: apk.length);
      final run = await download(sha: apkSha);
      expect(run.errors, [DownloadManager.msgInterrupted]);
      expectNoInstallAndNoSuccess(run);
      expect(File(slot).lengthSync(), cut, reason: 'partial kept');
      expect(await dm.findResumableProgress(url: apkUrl, sha256: apkSha), cut / apk.length);
    }

    test('truncated stream keeps the partial; a 206 resume appends the rest', () async {
      await interruptAt(4000);
      adapter.requests.clear();
      adapter.handler = (o) => rangeServer(o, apk);
      final run = await download(sha: apkSha);
      expect(adapter.requests.single.headers['Range'], 'bytes=4000-');
      expect(run.errors, isEmpty);
      expect(File(slot).readAsBytesSync(), apk);
      expect(native.installCalls, [(slot, apkSha)]);
      expect(await dm.findResumableProgress(), isNull, reason: 'meta cleared');
    });

    test('a 200 answer to a Range request replaces the partial (no append)', () async {
      await interruptAt(4000);
      adapter.handler = (o) => ok200(apk); // server ignores Range
      final run = await download(sha: apkSha);
      expect(run.errors, isEmpty);
      expect(File(slot).lengthSync(), apk.length, reason: 'not 4000 + 10000');
      expect(native.installCalls, [(slot, apkSha)]);
    });

    test('a 206 starting at the wrong offset discards the partial', () async {
      await interruptAt(4000);
      adapter.handler = (o) => ResponseBody(chunked(apk), 206, headers: {
            'content-range': ['bytes 0-9999/10000'],
            'content-length': ['10000'],
          });
      final run = await download(sha: apkSha);
      expectNoInstallAndNoSuccess(run);
      expect(run.errors, [DownloadManager.msgBadRange]);
      expect(File(slot).existsSync(), isFalse);
      expect(await dm.findResumableProgress(), isNull);
    });

    test('a body longer than announced is aborted and discarded', () async {
      adapter.handler = (o) => ok200(apk, contentLength: 5000);
      final run = await download(sha: apkSha);
      expectNoInstallAndNoSuccess(run);
      expect(run.errors, [DownloadManager.msgTooLarge]);
      expect(File(slot).existsSync(), isFalse);
    });

    test('a partial for another release is not resumed', () async {
      await interruptAt(4000);
      adapter.requests.clear();
      final other = List<int>.generate(8000, (i) => (i * 7) & 0xFF);
      adapter.handler = (o) => rangeServer(o, other);
      final run = await download(
          url: 'https://cdn.maharoapp.com/apk/maharo-2.0.1.apk', sha: sha256Hex(other));
      expect(adapter.requests.single.headers.containsKey('Range'), isFalse);
      expect(run.errors, isEmpty);
      expect(File(slot).readAsBytesSync(), other);
    });
  });

  group('pause, cancel and stall', () {
    test('pause keeps the partial, reports paused and never installs', () async {
      adapter.handler = (o) => ok200(apk, stream: paced(apk));
      var paused = false;
      final run = await download(
        sha: apkSha,
        onProgress: (p) {
          if (p > 0.2 && !paused) {
            paused = true;
            dm.pauseDownload();
          }
        },
      );
      expectNoInstallAndNoSuccess(run);
      expect(run.paused, hasLength(1));
      expect(run.errors, isEmpty);
      final size = File(slot).lengthSync();
      expect(size, greaterThan(0));
      expect(size, lessThan(apk.length));
      expect(native.stopCalls, greaterThanOrEqualTo(1));
      expect(await dm.findResumableProgress(url: apkUrl, sha256: apkSha), isNotNull);
    });

    test('cancel reports "Download cancelled" and never installs', () async {
      adapter.handler = (o) => ok200(apk, stream: paced(apk));
      final run = await download(
        sha: apkSha,
        onProgress: (p) {
          if (p > 0.2) dm.cancelDownload();
        },
      );
      expectNoInstallAndNoSuccess(run);
      expect(run.errors, ['Download cancelled']);
    });

    test('a stalled stream times out, keeps the partial and stops the service', () async {
      final controller = StreamController<Uint8List>();
      controller.add(Uint8List.fromList(apk.sublist(0, 2000))); // then silence
      adapter.handler = (o) => ok200(apk, stream: controller.stream);
      final watch = Stopwatch()..start();
      final run = await download(sha: apkSha);
      watch.stop();
      expectNoInstallAndNoSuccess(run);
      expect(run.errors, [DownloadManager.msgStalled]);
      expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
      expect(File(slot).lengthSync(), 2000);
      expect(native.startCalls, 1);
      expect(native.stopCalls, 1, reason: 'foreground service stopped on stall');
      expect(await dm.findResumableProgress(url: apkUrl, sha256: apkSha), 0.2);
      unawaited(controller.close());
    });
  });

  group('single-APK policy', () {
    test('cleanOldApks keeps only the APK slot, also in the legacy location', () async {
      final legacy = await Directory('${tmp.path}/legacy-external').create();
      dm = DownloadManager.forTesting(
        dio: Dio()..httpClientAdapter = adapter,
        stagingDir: () async => staging,
        legacyDir: () async => legacy,
        native: native,
      );
      await staging.create(recursive: true);
      for (final name in [
        DownloadManager.apkFileName,
        'old-1.apk',
        'x.bsdiff',
        DownloadManager.patchTmpFileName,
        'notes.txt',
      ]) {
        File('${staging.path}/$name').writeAsBytesSync([1, 2, 3]);
      }
      for (final name in [DownloadManager.apkFileName, 'other.apk', 'keep.txt']) {
        File('${legacy.path}/$name').writeAsBytesSync([1]);
      }
      await dm.cleanOldApks();
      final left = staging.listSync().map((e) => e.uri.pathSegments.last).toSet();
      expect(left, {DownloadManager.apkFileName, 'notes.txt'});
      final legacyLeft = legacy.listSync().map((e) => e.uri.pathSegments.last).toSet();
      expect(legacyLeft, {'keep.txt'});
    });

    test('a fresh download leaves exactly one APK on disk', () async {
      await staging.create(recursive: true);
      File('${staging.path}/stale.apk').writeAsBytesSync([9]);
      File(slot).writeAsBytesSync([1, 2, 3]); // partial of an unknown release
      adapter.handler = (o) => ok200(apk);
      final run = await download(sha: apkSha);
      expect(run.errors, isEmpty);
      final apks = staging
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.apk'))
          .map((f) => f.uri.pathSegments.last)
          .toList();
      expect(apks, [DownloadManager.apkFileName]);
      expect(File(slot).readAsBytesSync(), apk);
    });
  });

  group('retry install from the stored APK', () {
    setUp(() async {
      adapter.handler = (o) => ok200(apk);
      final run = await download(sha: apkSha);
      expect(native.installCalls, hasLength(1));
      expect(run.errors, isEmpty);
    });

    test('an intact stored APK is re-verified and installed with its hash', () async {
      final result = await dm.retryInstallFromStored(currentSha256: apkSha);
      expect(result['success'], isTrue);
      expect(native.installCalls, [(slot, apkSha), (slot, apkSha)]);
    });

    test('a tampered stored APK is deleted and never installed', () async {
      final bytes = File(slot).readAsBytesSync();
      bytes[1234] ^= 0xFF;
      File(slot).writeAsBytesSync(bytes);
      final result = await dm.retryInstallFromStored();
      expect(result, {'success': false, 'message': 'sha_mismatch'});
      expect(native.installCalls, hasLength(1), reason: 'no second install');
      expect(File(slot).existsSync(), isFalse);
    });

    test('a stored APK of an older release than the one on screen is discarded',
        () async {
      final result = await dm.retryInstallFromStored(currentSha256: sha256Hex([4, 5, 6]));
      expect(result['message'], 'stored_apk_outdated');
      expect(native.installCalls, hasLength(1));
      expect(File(slot).existsSync(), isFalse);
    });

    test('nothing stored means nothing installed', () async {
      File(slot).deleteSync();
      final result = await dm.retryInstallFromStored(currentSha256: apkSha);
      expect(result['message'], 'no_stored_apk');
      expect(native.installCalls, hasLength(1));
    });

    test('without a pinned signer certificate the retry is refused', () async {
      native.pinConfigured = false;
      final result = await dm.retryInstallFromStored(currentSha256: apkSha);
      expect(result['message'], 'signer_pin_missing');
      expect(native.installCalls, hasLength(1));
    });
  });

  group('delta patch', () {
    late List<int> oldApk;
    late List<int> newApk;
    late List<int> patch;
    late String newSha;

    setUp(() {
      // BSDIFF40 fixture made by test/fixtures/bspatch/make_fixture.py.
      oldApk = File('test/fixtures/bspatch/old.bin').readAsBytesSync();
      newApk = File('test/fixtures/bspatch/new.bin').readAsBytesSync();
      patch = File('test/fixtures/bspatch/patch.bsdiff').readAsBytesSync();
      newSha = sha256Hex(newApk);
      final installed = File('${tmp.path}/installed-base.apk')..writeAsBytesSync(oldApk);
      native.installedApkPath = installed.path;
    });

    Future<Run> deltaUpdate({required String patchSha, String? fullSha, List<int>? patchBody}) async {
      final run = Run();
      final sub = dm.installEvents.stream.listen(run.events.add);
      await dm.downloadAndApplyPatch(
        patchUrl: patchUrl,
        patchSha256: patchSha,
        fullApkSha256: fullSha ?? newSha,
        packageName: 'app.maharo',
        versionName: '2.0.0',
        onProgress: (p, s) => run.progress.add(p),
        onComplete: run.completed.add,
        onError: run.errors.add,
        fullDownloadUrl: apkUrl,
        fullFileSizeBytes: newApk.length,
      );
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      return run;
    }

    test('a valid patch rebuilds and installs the verified APK without a full download',
        () async {
      adapter.handler = (o) {
        expect(o.uri.toString(), patchUrl);
        return ok200(patch);
      };
      final run = await deltaUpdate(patchSha: sha256Hex(patch));
      expect(run.errors, isEmpty);
      expect(adapter.requests.map((r) => r.uri.toString()), [patchUrl]);
      expect(native.installCalls, [(slot, newSha)]);
      expect(File(slot).readAsBytesSync(), newApk);
      expect(run.events, ['installed']);
      final leftovers = staging.listSync().map((e) => e.uri.pathSegments.last).toSet();
      expect(leftovers, {DownloadManager.apkFileName}, reason: 'patch and temp files removed');
    });

    test('a patch with the wrong hash falls back to the SHA-gated full download',
        () async {
      adapter.handler = (o) => o.uri.toString() == patchUrl ? ok200(patch) : ok200(newApk);
      final run = await deltaUpdate(patchSha: sha256Hex([1]));
      expect(adapter.requests.map((r) => r.uri.toString()), [patchUrl, apkUrl]);
      expect(run.errors, isEmpty);
      expect(native.installCalls, [(slot, newSha)]);
    });

    test('a corrupt (but hash-matching) patch falls back to the full download',
        () async {
      final corrupt = List<int>.from(patch)..[60] ^= 0x55;
      adapter.handler = (o) => o.uri.toString() == patchUrl ? ok200(corrupt) : ok200(newApk);
      final run = await deltaUpdate(patchSha: sha256Hex(corrupt));
      expect(adapter.requests.map((r) => r.uri.toString()), [patchUrl, apkUrl]);
      expect(native.installCalls, [(slot, newSha)]);
      expect(run.errors, isEmpty);
    });

    test('a rebuilt APK with the wrong hash is never installed from the patch',
        () async {
      final wrongFull = sha256Hex([7, 7, 7]);
      adapter.handler = (o) => o.uri.toString() == patchUrl ? ok200(patch) : ok200(newApk);
      final run = await deltaUpdate(patchSha: sha256Hex(patch), fullSha: wrongFull);
      // Patch output fails the hash -> full download -> also fails the hash.
      expect(native.installCalls, isEmpty);
      expect(run.events, isEmpty);
      expect(run.errors, [DownloadManager.msgIntegrity]);
    });

    test('an invalid full-APK hash is refused before anything is downloaded', () async {
      final run = await deltaUpdate(patchSha: sha256Hex(patch), fullSha: '');
      expect(adapter.requests, isEmpty);
      expect(native.installCalls, isEmpty);
      expect(run.errors, [DownloadManager.msgMissingHash]);
    });
  });

  group('DownloadNotifier', () {
    test('a SHA mismatch ends in an error state, never in "installed"', () async {
      adapter.handler = (o) => ok200(apk);
      final notifier = DownloadNotifier(manager: dm);
      await notifier.startDownload(url: apkUrl, sha256: sha256Hex([0]), versionName: '2.0.0');
      await Future<void>.delayed(Duration.zero);
      expect(notifier.state.error, DownloadManager.msgIntegrity);
      expect(notifier.state.installedNow, isFalse);
      expect(notifier.state.isComplete, isFalse);
      notifier.dispose();
    });

    test('openStoredInstaller reports a re-verification failure instead of installing',
        () async {
      adapter.handler = (o) => ok200(apk);
      final notifier = DownloadNotifier(manager: dm);
      await notifier.startDownload(url: apkUrl, sha256: apkSha, versionName: '2.0.0');
      final bytes = File(slot).readAsBytesSync()..[10] ^= 1;
      File(slot).writeAsBytesSync(bytes);
      await notifier.openStoredInstaller(currentSha256: apkSha);
      expect(notifier.state.error, DownloadManager.msgIntegrity);
      expect(native.installCalls, hasLength(1));
      notifier.dispose();
    });
  });
}
