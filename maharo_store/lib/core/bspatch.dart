import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart'
    show BZip2Decoder, ByteOrder, InputStream, OutputStream;
import 'package:flutter/foundation.dart' show visibleForTesting;

/// Raised for any malformed, oversized or otherwise unusable patch.
class BspatchException implements Exception {
  const BspatchException(this.message);

  final String message;

  @override
  String toString() => 'BspatchException: $message';
}

/// Pure Dart bspatch for the BSDIFF40 format (bsdiff 4.x).
///
/// Patch layout: a 32-byte header ("BSDIFF40", compressed control length,
/// compressed diff length, new file size; each an 8-byte little-endian
/// sign-magnitude integer) followed by three independent bzip2 streams:
/// control triples (add length, copy length, seek), diff bytes and extra
/// bytes.
///
/// Memory stays bounded: [apply] runs in a background isolate, the old file
/// is read with positioned reads per control block, the diff and extra
/// blocks are decompressed into capped temporary files next to the output,
/// and the output is written to disk chunk by chunk.
class Bspatch {
  Bspatch._();

  /// Largest output accepted; also caps each decompressed block.
  static const int defaultMaxNewSize = 512 * 1024 * 1024;

  /// Cap for the decompressed control block (24 bytes per triple).
  static const int defaultMaxCtrlBytes = 32 * 1024 * 1024;

  /// Read/write chunk size of the patch loop.
  static const int defaultChunkSize = 1024 * 1024;

  /// Upper bound for one patch run.
  static const Duration defaultTimeout = Duration(minutes: 10);

  /// Applies [patchFile] to [oldFile] and writes [newFile], off the UI
  /// isolate. Returns true on success. Returns false, and removes any
  /// partial [newFile], when the patch is malformed, exceeds a bound
  /// ([maxNewSize], [expectedNewSize], the control-block cap, [timeout]) or
  /// any IO fails.
  static Future<bool> apply({
    required File oldFile,
    required File patchFile,
    required File newFile,
    int? expectedNewSize,
    int maxNewSize = defaultMaxNewSize,
    Duration timeout = defaultTimeout,
  }) async {
    final oldPath = oldFile.path;
    final patchPath = patchFile.path;
    final newPath = newFile.path;
    try {
      await Isolate.run(
        () => applySync(
          oldPath: oldPath,
          patchPath: patchPath,
          newPath: newPath,
          expectedNewSize: expectedNewSize,
          maxNewSize: maxNewSize,
          maxDuration: timeout,
        ),
        debugName: 'bspatch',
      ).timeout(timeout + const Duration(seconds: 30));
      return true;
    } catch (_) {
      try {
        if (await newFile.exists()) await newFile.delete();
      } catch (_) {}
      return false;
    }
  }

  /// Synchronous core of [apply]; runs inside the background isolate.
  /// Throws [BspatchException] for malformed or oversized input. Temporary
  /// files are always removed, and [newPath] is removed on failure.
  @visibleForTesting
  static void applySync({
    required String oldPath,
    required String patchPath,
    required String newPath,
    int? expectedNewSize,
    int maxNewSize = defaultMaxNewSize,
    int maxCtrlBytes = defaultMaxCtrlBytes,
    int chunkSize = defaultChunkSize,
    Duration? maxDuration,
  }) {
    if (chunkSize <= 0) {
      throw ArgumentError.value(chunkSize, 'chunkSize', 'must be positive');
    }
    final clock = Stopwatch()..start();
    void checkDeadline() {
      if (maxDuration != null && clock.elapsed > maxDuration) {
        throw const BspatchException('patching took too long');
      }
    }

    final diffPath = '$newPath.diff.tmp';
    final extraPath = '$newPath.extra.tmp';
    RandomAccessFile? patch;
    RandomAccessFile? old;
    RandomAccessFile? out;
    RandomAccessFile? diff;
    RandomAccessFile? extra;
    var success = false;
    try {
      patch = File(patchPath).openSync();
      final patchLen = patch.lengthSync();
      if (patchLen < 32) {
        throw const BspatchException('patch is shorter than its header');
      }
      final header = Uint8List(32);
      _readFully(patch, 0, header, 32);
      if (String.fromCharCodes(header, 0, 8) != 'BSDIFF40') {
        throw const BspatchException('bad magic');
      }
      final ctrlLen = _offtin(header, 8);
      final diffLen = _offtin(header, 16);
      final newSize = _offtin(header, 24);
      if (ctrlLen < 0 || diffLen < 0 || newSize < 0) {
        throw const BspatchException('negative length in header');
      }
      if (ctrlLen > patchLen - 32 || diffLen > patchLen - 32 - ctrlLen) {
        throw const BspatchException('header lengths exceed the patch size');
      }
      if (newSize > maxNewSize) {
        throw const BspatchException('new size exceeds the limit');
      }
      if (expectedNewSize != null && newSize != expectedNewSize) {
        throw const BspatchException('new size does not match the release');
      }
      final extraStart = 32 + ctrlLen + diffLen;
      final extraLen = patchLen - extraStart;

      // Control block: small, kept in memory (capped).
      final ctrlBuilder = BytesBuilder(copy: true);
      _decompress(patch, 32, ctrlLen, maxCtrlBytes, (chunk, n) {
        ctrlBuilder.add(Uint8List.sublistView(chunk, 0, n));
      });
      final ctrl = ctrlBuilder.takeBytes();
      checkDeadline();

      // Diff and extra blocks go to capped temp files. Every new byte comes
      // from exactly one of them, so together they cannot exceed newSize.
      final diffSize = _decompressToFile(patch, 32 + ctrlLen, diffLen, newSize, diffPath);
      checkDeadline();
      final extraSize = _decompressToFile(
          patch, extraStart, extraLen, newSize - diffSize, extraPath);
      checkDeadline();

      diff = File(diffPath).openSync();
      extra = File(extraPath).openSync();
      old = File(oldPath).openSync();
      out = File(newPath).openSync(mode: FileMode.write);
      final diffReader = _SequentialReader(diff, diffSize, 'diff');
      final extraReader = _SequentialReader(extra, extraSize, 'extra');
      final oldSize = old.lengthSync();
      final posBound = oldSize + newSize;
      final buf = Uint8List(chunkSize);
      final oldBuf = Uint8List(chunkSize);

      var ctrlPos = 0;
      var oldPos = 0;
      var newPos = 0;
      while (newPos < newSize) {
        checkDeadline();
        if (ctrlPos + 24 > ctrl.length) {
          throw const BspatchException('control block exhausted');
        }
        final addLen = _offtin(ctrl, ctrlPos);
        final copyLen = _offtin(ctrl, ctrlPos + 8);
        final seek = _offtin(ctrl, ctrlPos + 16);
        ctrlPos += 24;
        if (addLen < 0 || copyLen < 0) {
          throw const BspatchException('negative length in control triple');
        }
        if (addLen > newSize - newPos) {
          throw const BspatchException('add overruns the new file');
        }

        // new = diff + old (old bytes outside the old file count as 0).
        var remaining = addLen;
        while (remaining > 0) {
          final n = math.min(remaining, chunkSize);
          diffReader.readExactly(buf, n);
          _readOld(old, oldSize, oldPos, n, oldBuf);
          for (var i = 0; i < n; i++) {
            buf[i] = (buf[i] + oldBuf[i]) & 0xFF;
          }
          out.writeFromSync(buf, 0, n);
          oldPos += n;
          newPos += n;
          remaining -= n;
          checkDeadline();
        }

        if (copyLen > newSize - newPos) {
          throw const BspatchException('copy overruns the new file');
        }
        remaining = copyLen;
        while (remaining > 0) {
          final n = math.min(remaining, chunkSize);
          extraReader.readExactly(buf, n);
          out.writeFromSync(buf, 0, n);
          newPos += n;
          remaining -= n;
        }

        if (seek > posBound || seek < -posBound) {
          throw const BspatchException('seek out of range');
        }
        oldPos += seek;
        if (oldPos > posBound || oldPos < -posBound) {
          throw const BspatchException('old position out of range');
        }
      }
      out.flushSync();
      success = true;
    } finally {
      for (final f in [patch, old, out, diff, extra]) {
        try {
          f?.closeSync();
        } catch (_) {}
      }
      for (final p in [diffPath, extraPath, if (!success) newPath]) {
        try {
          final f = File(p);
          if (f.existsSync()) f.deleteSync();
        } catch (_) {}
      }
    }
  }

  /// Read 8-byte little-endian sign-magnitude integer from [buf] at [off].
  static int _offtin(Uint8List buf, int off) {
    var y = buf[off + 7] & 0x7F;
    for (var i = 6; i >= 0; i--) {
      y = (y << 8) | buf[off + i];
    }
    return (buf[off + 7] & 0x80) != 0 ? -y : y;
  }

  static void _readFully(RandomAccessFile f, int position, Uint8List dst, int n) {
    f.setPositionSync(position);
    var got = 0;
    while (got < n) {
      final r = f.readIntoSync(dst, got, n);
      if (r <= 0) throw const BspatchException('unexpected end of file');
      got += r;
    }
  }

  /// Fills dst[0..n) with old bytes at [oldPos], 0 where outside the file.
  static void _readOld(
      RandomAccessFile old, int oldSize, int oldPos, int n, Uint8List dst) {
    dst.fillRange(0, n, 0);
    final from = math.max(oldPos, 0);
    final to = math.min(oldPos + n, oldSize);
    if (from >= to) return;
    old.setPositionSync(from);
    var off = from - oldPos;
    final end = to - oldPos;
    while (off < end) {
      final r = old.readIntoSync(dst, off, end);
      if (r <= 0) throw const BspatchException('old file shrank while patching');
      off += r;
    }
  }

  /// Decompresses one bzip2 stream (CRC-verified) into [sink], refusing
  /// output beyond [cap] bytes. Returns the decompressed size.
  static int _decompress(RandomAccessFile patch, int offset, int length, int cap,
      void Function(Uint8List chunk, int n) sink) {
    // An absent block holds no bytes (reference bspatch only fails once it
    // actually needs data from it).
    if (length == 0) return 0;
    final input = _RangeInput(patch, offset, length);
    final output = _CappedSink(cap, sink);
    if (!BZip2Decoder().decodeStream(input, output, verify: true)) {
      throw const BspatchException('corrupt bzip2 block');
    }
    output.flush();
    return output.length;
  }

  static int _decompressToFile(
      RandomAccessFile patch, int offset, int length, int cap, String path) {
    final f = File(path).openSync(mode: FileMode.write);
    try {
      return _decompress(patch, offset, length, cap, (chunk, n) {
        f.writeFromSync(chunk, 0, n);
      });
    } finally {
      f.closeSync();
    }
  }
}

/// Reads exactly the bytes a block holds, in order, and no more.
class _SequentialReader {
  _SequentialReader(this._file, this._size, this._name);

  final RandomAccessFile _file;
  final int _size;
  final String _name;
  int _pos = 0;

  void readExactly(Uint8List dst, int n) {
    if (n > _size - _pos) {
      throw BspatchException('$_name block exhausted');
    }
    _file.setPositionSync(_pos);
    var got = 0;
    while (got < n) {
      final r = _file.readIntoSync(dst, got, n);
      if (r <= 0) throw BspatchException('$_name block truncated');
      got += r;
    }
    _pos += n;
  }
}

/// bzip2 input over one byte range of the patch file, buffered. Reading past
/// the range throws, so a truncated block fails instead of being padded.
class _RangeInput extends InputStream {
  _RangeInput(this._file, this._start, this._length)
      : super(byteOrder: ByteOrder.littleEndian);

  final RandomAccessFile _file;
  final int _start;
  final int _length;
  final Uint8List _buf = Uint8List(64 * 1024);
  int _bufStart = 0;
  int _bufLen = 0;
  int _pos = 0;

  @override
  int get position => _pos;

  @override
  set position(int v) => setPosition(v);

  @override
  int get length => _length - _pos;

  @override
  bool get isEOS => _pos >= _length;

  @override
  bool open() => true;

  @override
  Future<void> close() async {}

  @override
  void closeSync() {}

  @override
  void reset() => _pos = 0;

  @override
  void setPosition(int v) {
    if (v < 0 || v > _length) {
      throw const BspatchException('seek outside the compressed block');
    }
    _pos = v;
  }

  @override
  void rewind([int length = 1]) => setPosition(_pos - length);

  @override
  void skip(int length) => setPosition(_pos + length);

  @override
  InputStream subset({int? position, int? length, int? bufferSize}) =>
      throw UnsupportedError('subset');

  @override
  int readByte() {
    if (_pos >= _length) {
      throw const BspatchException('compressed block truncated');
    }
    if (_pos < _bufStart || _pos >= _bufStart + _bufLen) _fill();
    final b = _buf[_pos - _bufStart];
    _pos++;
    return b;
  }

  void _fill() {
    final want = math.min(_buf.length, _length - _pos);
    _file.setPositionSync(_start + _pos);
    var got = 0;
    while (got < want) {
      final r = _file.readIntoSync(_buf, got, want);
      if (r <= 0) throw const BspatchException('compressed block truncated');
      got += r;
    }
    _bufStart = _pos;
    _bufLen = got;
  }

  @override
  Uint8List toUint8List() => throw UnsupportedError('toUint8List');
}

/// bzip2 output that forwards buffered chunks and throws past [_cap] bytes
/// (decompression-bomb guard).
class _CappedSink extends OutputStream {
  _CappedSink(this._cap, this._onChunk)
      : super(byteOrder: ByteOrder.littleEndian);

  final int _cap;
  final void Function(Uint8List chunk, int n) _onChunk;
  final Uint8List _buf = Uint8List(64 * 1024);
  int _bufLen = 0;
  int _length = 0;

  @override
  int get length => _length;

  @override
  void clear() => throw UnsupportedError('clear');

  @override
  void flush() {
    if (_bufLen > 0) {
      _onChunk(_buf, _bufLen);
      _bufLen = 0;
    }
  }

  @override
  void writeByte(int value) {
    if (_length >= _cap) {
      throw const BspatchException('decompressed block exceeds its bound');
    }
    _buf[_bufLen++] = value;
    _length++;
    if (_bufLen == _buf.length) flush();
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    final n = length ?? bytes.length;
    for (var i = 0; i < n; i++) {
      writeByte(bytes[i]);
    }
  }

  @override
  void writeStream(InputStream stream) {
    while (!stream.isEOS) {
      writeByte(stream.readByte());
    }
  }

  @override
  Uint8List subset(int start, [int? end]) => throw UnsupportedError('subset');
}
