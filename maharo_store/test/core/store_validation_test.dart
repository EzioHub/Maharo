// Release metadata from the API is untrusted: only 64-hex SHA-256 digests
// and absolute https URLs are accepted.

import 'package:flutter_test/flutter_test.dart';
import 'package:maharo_store/core/store_validation.dart';

void main() {
  const sha = 'adfe56595acdd3d42e6df0f0d29fa7363feb22ee1539e3fd3c3faacbfd8f0c28';

  group('normalizeSha256', () {
    test('accepts 64 hex characters, trimming and lower-casing', () {
      expect(normalizeSha256(sha), sha);
      expect(normalizeSha256('  ${sha.toUpperCase()}\n'), sha);
      expect(isValidSha256(sha), isTrue);
    });

    test('rejects missing, empty, short, long and non-hex values', () {
      for (final bad in <String?>[
        null,
        '',
        '   ',
        sha.substring(1),
        '${sha}0',
        'g${sha.substring(1)}',
        'sha256:$sha',
        sha.replaceRange(10, 12, ':'),
      ]) {
        expect(normalizeSha256(bad), isNull, reason: 'value: $bad');
        expect(isValidSha256(bad), isFalse, reason: 'value: $bad');
      }
    });
  });

  group('parseHttpsUrl', () {
    test('accepts absolute https URLs with a host', () {
      final uri = parseHttpsUrl('https://cdn.maharoapp.com/apk/maharo-2.0.0.apk');
      expect(uri, isNotNull);
      expect(uri!.host, 'cdn.maharoapp.com');
      expect(parseHttpsUrl('  HTTPS://cdn.maharoapp.com/a.apk  '), isNotNull);
    });

    test('rejects http, other schemes, relative URLs and user info', () {
      for (final bad in <String?>[
        null,
        '',
        'http://cdn.maharoapp.com/a.apk',
        'ftp://cdn.maharoapp.com/a.apk',
        'file:///sdcard/a.apk',
        'content://app.maharo.store.fileprovider/apks/maharo-latest.apk',
        '/store/a.apk',
        'cdn.maharoapp.com/a.apk',
        'https:///a.apk',
        'https://user:pass@cdn.maharoapp.com/a.apk',
      ]) {
        expect(parseHttpsUrl(bad), isNull, reason: 'value: $bad');
      }
    });
  });
}
