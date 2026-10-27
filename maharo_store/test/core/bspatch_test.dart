// Bspatch (BSDIFF40) tests.
//
// The known-valid fixture in test/fixtures/bspatch/ is built by
// make_fixture.py with CPython's bz2 module (libbzip2) and hand-laid control
// triples, and checked there by a transcription of the reference bspatch.c
// loop — so it does not depend on the Dart code under test. Malformed
// patches below are derived from it or assembled with the archive package's
// bzip2 encoder.

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart' show BZip2Encoder;
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:maharo_store/core/bspatch.dart';

const _fixtureDir = 'test/fixtures/bspatch';
const _fixtureNewSha =
    'adfe56595acdd3d42e6df0f0d29fa7363feb22ee1539e3fd3c3faacbfd8f0c28';

/// bsdiff.c offtout: 8-byte little-endian sign-magnitude.
Uint8List offtout(int x) {
  final out = Uint8List(8);
  var y = x < 0 ? -x : x;
  for (var i = 0; i < 8; i++) {
    out[i] = y & 0xFF;
    y >>= 8;
  }
  if (x < 0) out[7] |= 0x80;
  return out;
}

Uint8List ctrlBlock(List<List<int>> triples) {
  final b = BytesBuilder();
  for (final t in triples) {
    b
      ..add(offtout(t[0]))
      ..add(offtout(t[1]))
      ..add(offtout(t[2]));
  }
  return b.takeBytes();
}

/// Assembles a BSDIFF40 patch from raw (uncompressed) blocks.
Uint8List buildPatch({
  required List<int> ctrl,
  required List<int> diff,
  required List<int> extra,
  required int newSize,
}) {
  final enc = BZip2Encoder();
  final bzCtrl = enc.encodeBytes(ctrl);
  final bzDiff = enc.encodeBytes(diff);
  final bzExtra = enc.encodeBytes(extra);
  return (BytesBuilder()
        ..add('BSDIFF40'.codeUnits)
        ..add(offtout(bzCtrl.length))
        ..add(offtout(bzDiff.length))
        ..add(offtout(newSize))
        ..add(bzCtrl)
        ..add(bzDiff)
        ..add(bzExtra))
      .takeBytes();
}

/// Straightforward bspatch semantics used to compute expected outputs for
/// synthetic patches (independent of the chunked file IO under test).
Uint8List referenceApply(Uint8List old, List<List<int>> triples, Uint8List diff,
    Uint8List extra, int newSize) {
  final out = Uint8List(newSize);
  var oldPos = 0, newPos = 0, d = 0, e = 0;
  for (final t in triples) {
    for (var i = 0; i < t[0]; i++) {
      final p = oldPos + i;
      final ob = (p >= 0 && p < old.length) ? old[p] : 0;
      out[newPos + i] = (diff[d + i] + ob) & 0xFF;
    }
    newPos += t[0];
    oldPos += t[0];
    d += t[0];
    out.setRange(newPos, newPos + t[1], extra, e);
    newPos += t[1];
    e += t[1];
    oldPos += t[2];
  }
  return out;
}

String sha256Hex(List<int> bytes) => crypto.sha256.convert(bytes).toString();

void main() {
  late Directory tmp;
  late Uint8List fixtureOld;
  late Uint8List fixtureNew;
  late Uint8List fixturePatch;

  setUpAll(() {
    fixtureOld = File('$_fixtureDir/old.bin').readAsBytesSync();
    fixtureNew = File('$_fixtureDir/new.bin').readAsBytesSync();
    fixturePatch = File('$_fixtureDir/patch.bsdiff').readAsBytesSync();
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('bspatch_test_');
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  File write(String name, List<int> bytes) =>
      File('${tmp.path}/$name')..writeAsBytesSync(bytes);

  /// Runs the public (isolate) entry point.
  Future<(bool, File)> apply(List<int> old, List<int> patch,
      {int? expectedNewSize, int maxNewSize = Bspatch.defaultMaxNewSize}) async {
    final out = File('${tmp.path}/new.apk');
    final ok = await Bspatch.apply(
      oldFile: write('old.apk', old),
      patchFile: write('patch.bsdiff', patch),
      newFile: out,
      expectedNewSize: expectedNewSize,
      maxNewSize: maxNewSize,
    );
    return (ok, out);
  }

  /// Patching leaves nothing behind but the output (temp blocks removed).
  void expectNoTempFiles() {
    final leftovers = tmp
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.tmp'))
        .toList();
    expect(leftovers, isEmpty);
  }

  group('known BSDIFF40 fixture (libbzip2-compressed, made outside Dart)', () {
    test('fixture files are the ones make_fixture.py produced', () {
      expect(sha256Hex(fixtureNew), _fixtureNewSha);
      expect(String.fromCharCodes(fixturePatch.sublist(0, 8)), 'BSDIFF40');
    });

    test('apply (background isolate) rebuilds new.bin byte for byte', () async {
      final (ok, out) = await apply(fixtureOld, fixturePatch);
      expect(ok, isTrue);
      expect(out.readAsBytesSync(), fixtureNew);
      expect(sha256Hex(out.readAsBytesSync()), _fixtureNewSha);
      expectNoTempFiles();
    });

    test('chunk size does not change the result (1, 3, 7, 64 KiB)', () {
      final old = write('old.apk', fixtureOld);
      final patch = write('patch.bsdiff', fixturePatch);
      for (final chunk in [1, 3, 7, 64 * 1024]) {
        final out = '${tmp.path}/new-$chunk.apk';
        Bspatch.applySync(
          oldPath: old.path,
          patchPath: patch.path,
          newPath: out,
          chunkSize: chunk,
        );
        expect(File(out).readAsBytesSync(), fixtureNew, reason: 'chunk $chunk');
      }
      expectNoTempFiles();
    });

    test('expectedNewSize must match the header', () async {
      final (ok, _) = await apply(fixtureOld, fixturePatch,
          expectedNewSize: fixtureNew.length);
      expect(ok, isTrue);
      final (bad, out) = await apply(fixtureOld, fixturePatch,
          expectedNewSize: fixtureNew.length + 1);
      expect(bad, isFalse);
      expect(out.existsSync(), isFalse);
    });

    test('a missing old file fails cleanly', () async {
      final out = File('${tmp.path}/new.apk');
      final ok = await Bspatch.apply(
        oldFile: File('${tmp.path}/does-not-exist.apk'),
        patchFile: write('patch.bsdiff', fixturePatch),
        newFile: out,
      );
      expect(ok, isFalse);
      expect(out.existsSync(), isFalse);
    });
  });

  group('malformed or hostile patches are rejected and leave no output', () {
    Uint8List mutate(void Function(Uint8List p) change) {
      final p = Uint8List.fromList(fixturePatch);
      change(p);
      return p;
    }

    void setHeader(Uint8List p, int offset, int value) =>
        p.setRange(offset, offset + 8, offtout(value));

    final cases = <String, Uint8List Function()>{
      'shorter than the 32-byte header': () => fixturePatch.sublist(0, 31),
      'empty file': () => Uint8List(0),
      'wrong magic': () => mutate((p) => p[7] = 0x31), // BSDIFF41
      'negative control length': () => mutate((p) => setHeader(p, 8, -1)),
      'control length beyond the patch': () =>
          mutate((p) => setHeader(p, 8, fixturePatch.length)),
      'diff length beyond the patch': () =>
          mutate((p) => setHeader(p, 16, fixturePatch.length)),
      'huge (sign-magnitude) lengths': () =>
          mutate((p) => setHeader(p, 8, 0x7FFFFFFFFFFFFFFF)),
      'negative new size': () => mutate((p) => setHeader(p, 24, -160)),
      'new size above the 512 MiB default limit': () =>
          mutate((p) => setHeader(p, 24, 1 << 40)),
      'corrupted bzip2 data': () => mutate((p) => p[60] ^= 0x55),
      // Control stream = patch[32..]: "BZh9", 6-byte block magic, then the
      // 4-byte block CRC at 42..45. Only the CRC check can catch this one.
      'bzip2 block CRC does not match intact data': () => mutate((p) => p[43] ^= 0x01),
      // The extra stream is the last 67 bytes; cutting 40 ends it mid-block.
      'truncated extra block (cut inside the compressed data)': () =>
          fixturePatch.sublist(0, fixturePatch.length - 40),
      'truncated diff block': () => mutate((p) => setHeader(p, 16, 40)),
    };

    cases.forEach((name, build) {
      test(name, () async {
        final (ok, out) = await apply(fixtureOld, build());
        expect(ok, isFalse);
        expect(out.existsSync(), isFalse);
        expectNoTempFiles();
      });
    });

    test(
        'a missing end-of-stream trailer after complete data decodes like '
        'libbzip2-based bspatch; the output is still exact', () async {
      // Only the 10-byte bzip2 end marker + CRC of the extra stream is cut.
      // The data block itself is complete and CRC-checked, so the rebuilt
      // file is identical; integrity is in any case gated by the APK SHA-256.
      final (ok, out) =
          await apply(fixtureOld, fixturePatch.sublist(0, fixturePatch.length - 10));
      expect(ok, isTrue);
      expect(out.readAsBytesSync(), fixtureNew);
    });

    test('new size above maxNewSize is refused', () async {
      final (ok, out) =
          await apply(fixtureOld, fixturePatch, maxNewSize: fixtureNew.length - 1);
      expect(ok, isFalse);
      expect(out.existsSync(), isFalse);
    });

    final old = Uint8List.fromList(List.generate(64, (i) => i));

    final controlCases = <String, Uint8List Function()>{
      'negative add length': () => buildPatch(
            ctrl: ctrlBlock([
              [-1, 0, 0],
              [16, 0, 0],
            ]),
            diff: Uint8List(16),
            extra: Uint8List(0),
            newSize: 16),
      'negative copy length': () => buildPatch(
            ctrl: ctrlBlock([
              [0, -4, 0],
            ]),
            diff: Uint8List(0),
            extra: Uint8List(4),
            newSize: 4),
      'add overruns the new size': () => buildPatch(
            ctrl: ctrlBlock([
              [17, 0, 0],
            ]),
            diff: Uint8List(17),
            extra: Uint8List(0),
            newSize: 16),
      'copy overruns the new size': () => buildPatch(
            ctrl: ctrlBlock([
              [8, 9, 0],
            ]),
            diff: Uint8List(8),
            extra: Uint8List(9),
            newSize: 16),
      'diff block shorter than the adds need': () => buildPatch(
            ctrl: ctrlBlock([
              [16, 0, 0],
            ]),
            diff: Uint8List(15),
            extra: Uint8List(0),
            newSize: 16),
      'extra block shorter than the copies need': () => buildPatch(
            ctrl: ctrlBlock([
              [0, 16, 0],
            ]),
            diff: Uint8List(0),
            extra: Uint8List(15),
            newSize: 16),
      'control block ends before the new file is complete': () => buildPatch(
            ctrl: ctrlBlock([
              [8, 0, 0],
            ]),
            diff: Uint8List(16),
            extra: Uint8List(0),
            newSize: 16),
      'seek far outside both files': () => buildPatch(
            ctrl: ctrlBlock([
              [4, 0, 1 << 50],
              [4, 0, 0],
            ]),
            diff: Uint8List(8),
            extra: Uint8List(0),
            newSize: 8),
      'decompression bomb: 4 MiB extra block for a 16-byte file': () =>
          buildPatch(
            ctrl: ctrlBlock([
              [0, 16, 0],
            ]),
            diff: Uint8List(0),
            extra: Uint8List(4 * 1024 * 1024),
            newSize: 16),
      'decompression bomb: diff block larger than the new file': () =>
          buildPatch(
            ctrl: ctrlBlock([
              [16, 0, 0],
            ]),
            diff: Uint8List(1024 * 1024),
            extra: Uint8List(0),
            newSize: 16),
    };

    controlCases.forEach((name, build) {
      test(name, () async {
        final (ok, out) = await apply(old, build());
        expect(ok, isFalse);
        expect(out.existsSync(), isFalse);
        expectNoTempFiles();
      });
    });

    test('control block above its cap is refused', () {
      final patch = write(
          'cap.bsdiff',
          buildPatch(
            ctrl: ctrlBlock([
              [8, 0, 0],
              [8, 0, 0],
            ]),
            diff: Uint8List(16),
            extra: Uint8List(0),
            newSize: 16,
          ));
      final oldFile = write('old.apk', old);
      final out = '${tmp.path}/capped.apk';
      expect(
        () => Bspatch.applySync(
          oldPath: oldFile.path,
          patchPath: patch.path,
          newPath: out,
          maxCtrlBytes: 24, // only one triple allowed
        ),
        throwsA(isA<BspatchException>()),
      );
      expect(File(out).existsSync(), isFalse);
      // The same patch is fine with the default cap.
      Bspatch.applySync(oldPath: oldFile.path, patchPath: patch.path, newPath: out);
      expect(File(out).lengthSync(), 16);
    });
  });

  test('large synthetic patch crosses many chunk boundaries correctly', () async {
    final rnd = Random(42);
    final old = Uint8List.fromList(List.generate(300000, (_) => rnd.nextInt(256)));
    final triples = <List<int>>[
      [70000, 5000, -20000], // sparse edits, then extra, then seek back
      [123457, 0, 100000],
      [60000, 2500, 10000], // old range 273457..333457 runs past the end
      [12000, 777, 0], // old range entirely past the end (old bytes = 0)
    ];
    final addTotal = triples.fold<int>(0, (s, t) => s + t[0]);
    final copyTotal = triples.fold<int>(0, (s, t) => s + t[1]);
    final diff = Uint8List(addTotal);
    for (var i = 0; i < diff.length; i += 997) {
      diff[i] = rnd.nextInt(256);
    }
    final extra = Uint8List.fromList(List.generate(copyTotal, (_) => rnd.nextInt(256)));
    final newSize = addTotal + copyTotal;
    final expected = referenceApply(old, triples, diff, extra, newSize);
    final patchBytes = buildPatch(
        ctrl: ctrlBlock(triples), diff: diff, extra: extra, newSize: newSize);

    final (ok, out) = await apply(old, patchBytes, expectedNewSize: newSize);
    expect(ok, isTrue);
    expect(sha256Hex(out.readAsBytesSync()), sha256Hex(expected));

    final small = '${tmp.path}/small-chunks.apk';
    Bspatch.applySync(
      oldPath: '${tmp.path}/old.apk',
      patchPath: '${tmp.path}/patch.bsdiff',
      newPath: small,
      chunkSize: 4093,
    );
    expect(sha256Hex(File(small).readAsBytesSync()), sha256Hex(expected));
    expectNoTempFiles();
  });
}
