// A delta patch is used only when it rebuilds exactly the release on screen
// from exactly the installed version, with well-formed hashes and URL.

import 'package:flutter_test/flutter_test.dart';
import 'package:maharo_store/models/store_patch.dart';
import 'package:maharo_store/models/store_version.dart';

const fullSha = 'adfe56595acdd3d42e6df0f0d29fa7363feb22ee1539e3fd3c3faacbfd8f0c28';
const patchSha = 'c2fee9d2aca59967b54e7e8f7bdfaddd14d485a30841dac49a8b6f728bf85a4f';

StoreVersion latest({String sha = fullSha, int code = 20}) => StoreVersion(
      id: 'v20',
      versionName: '2.0.0',
      versionCode: code,
      changelog: '',
      changelogEn: '',
      downloadUrl: 'https://cdn.maharoapp.com/apk/maharo-2.0.0.apk',
      fileSizeBytes: 1000,
      sha256: sha,
      createdAt: DateTime(2026, 10, 20),
    );

StorePatch patch({
  String url = 'https://cdn.maharoapp.com/apk/19-20.bsdiff',
  String pSha = patchSha,
  String fSha = fullSha,
  int from = 19,
  int to = 20,
}) =>
    StorePatch(
      patchUrl: url,
      patchSizeBytes: 100,
      patchSha256: pSha,
      fullApkSha256: fSha,
      fromVersionCode: from,
      toVersionCode: to,
    );

void main() {
  test('a consistent patch is usable (hash comparison ignores case)', () {
    expect(patch(fSha: fullSha.toUpperCase()).isUsableFor(latest(), installedVersionCode: 19),
        isTrue);
  });

  test('inconsistent or malformed patches are not used', () {
    final cases = <String, bool>{
      'from another installed version': patch(from: 18).isUsableFor(latest(), installedVersionCode: 19),
      'to another release': patch(to: 21).isUsableFor(latest(), installedVersionCode: 19),
      'rebuilds a different APK hash': patch(fSha: patchSha).isUsableFor(latest(), installedVersionCode: 19),
      'release without a valid hash': patch().isUsableFor(latest(sha: ''), installedVersionCode: 19),
      'malformed patch hash': patch(pSha: 'xyz').isUsableFor(latest(), installedVersionCode: 19),
      'http patch URL': patch(url: 'http://cdn.maharoapp.com/a.bsdiff')
          .isUsableFor(latest(), installedVersionCode: 19),
      'unknown installed version': patch().isUsableFor(latest(), installedVersionCode: 0),
    };
    cases.forEach((name, usable) => expect(usable, isFalse, reason: name));
  });

  test('fromJson accepts the API shape and rejects missing fields', () {
    final p = StorePatch.fromJson({
      'patchUrl': 'https://cdn.maharoapp.com/apk/19-20.bsdiff',
      'patchSizeBytes': 100,
      'patchSha256': patchSha,
      'fullApkSha256': fullSha,
      'fromVersionCode': 19,
      'toVersionCode': 20,
    });
    expect(p.toVersionCode, 20);
    expect(() => StorePatch.fromJson({'patchUrl': 'https://x.test/p'}), throwsA(anything));
  });
}
