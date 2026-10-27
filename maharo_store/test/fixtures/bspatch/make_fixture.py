"""Builds the BSDIFF40 fixture used by test/core/bspatch_test.dart.

The fixture is made independently of the Dart code under test:

* the control triples are laid out by hand (see TRIPLES below) and follow the
  BSDIFF40 format of Colin Percival's bsdiff 4.x: a 32-byte header
  ("BSDIFF40", bzip2 control length, bzip2 diff length, new size; each an
  8-byte little-endian sign-magnitude integer), then three bzip2 streams;
* the three blocks are compressed with CPython's bz2 module (libbzip2), not
  with the Dart `archive` encoder;
* reference_bspatch() is a line-by-line transcription of the bspatch.c loop
  and must rebuild new.bin from old.bin + patch.bsdiff before anything is
  written.

The triples cover: an add with a few changed bytes, an add of identical
bytes, a negative seek, an add whose old range runs past the end of the old
file (those old bytes count as 0), an empty copy, and extra-byte copies.

Run (standard library only):  python -I make_fixture.py <output_dir>
"""
import bz2
import hashlib
import os
import struct
import sys


def offtout(x):
    """bsdiff.c offtout: 8-byte little-endian sign-magnitude."""
    y = -x if x < 0 else x
    b = bytearray(struct.pack("<Q", y))
    if x < 0:
        b[7] |= 0x80
    return bytes(b)


def offtin(buf, off):
    y = struct.unpack_from("<Q", buf, off)[0] & 0x7FFFFFFFFFFFFFFF
    return -y if buf[off + 7] & 0x80 else y


def reference_bspatch(old, patch):
    """Transcription of bspatch.c (bsdiff 4.3) main loop."""
    if len(patch) < 32 or patch[:8] != b"BSDIFF40":
        raise ValueError("corrupt patch")
    bzctrllen = offtin(patch, 8)
    bzdatalen = offtin(patch, 16)
    newsize = offtin(patch, 24)
    if bzctrllen < 0 or bzdatalen < 0 or newsize < 0:
        raise ValueError("corrupt patch")
    ctrl = bz2.decompress(patch[32:32 + bzctrllen])
    data = bz2.decompress(patch[32 + bzctrllen:32 + bzctrllen + bzdatalen])
    extra = bz2.decompress(patch[32 + bzctrllen + bzdatalen:])
    new = bytearray(newsize)
    oldpos = newpos = 0
    c = d = e = 0
    while newpos < newsize:
        x, y, z = offtin(ctrl, c), offtin(ctrl, c + 8), offtin(ctrl, c + 16)
        c += 24
        if x < 0 or y < 0 or newpos + x > newsize:
            raise ValueError("corrupt patch")
        new[newpos:newpos + x] = data[d:d + x]
        d += x
        for i in range(x):
            if 0 <= oldpos + i < len(old):
                new[newpos + i] = (new[newpos + i] + old[oldpos + i]) & 0xFF
        newpos += x
        oldpos += x
        if newpos + y > newsize:
            raise ValueError("corrupt patch")
        new[newpos:newpos + y] = extra[e:e + y]
        e += y
        newpos += y
        oldpos += z
    return bytes(new)


OLD = (b"The quick brown fox jumps over the lazy dog. " * 3) + bytes(range(256))


def new_byte_rules(step, i, old_byte):
    """How each add step turns old bytes into new bytes."""
    if step == 0:  # copy 40 bytes, upper-casing "quick"
        return old_byte - 32 if 4 <= i < 9 else old_byte
    if step == 1:  # 50 identical bytes
        return old_byte
    if step == 2:  # 30 bytes, each +1 (mod 256)
        return (old_byte + 1) & 0xFF
    if step == 3:  # 16 bytes; positions past the old end use fresh values
        return (0xA0 + i) & 0xFF
    raise AssertionError(step)


# (add length, extra bytes copied after the add, seek applied afterwards)
TRIPLES = [
    (40, b"MAHARO-STORE", 20),       # oldpos 0 -> 40 -> 60
    (50, b"", -100),                 # oldpos 60 -> 110 -> 10 (negative seek)
    (30, b"\x00\xff\x10\x20\x30", 343),  # oldpos 10 -> 40 -> 383
    (16, b"THE-END", 0),             # old bytes 383..398; 391.. are past EOF
]


def build():
    ctrl = bytearray()
    diff = bytearray()
    extra = bytearray()
    new = bytearray()
    oldpos = 0
    for step, (add, copy, seek) in enumerate(TRIPLES):
        for i in range(add):
            p = oldpos + i
            in_range = 0 <= p < len(OLD)
            ob = OLD[p] if in_range else 0
            nb = new_byte_rules(step, i, ob) & 0xFF
            new.append(nb)
            diff.append((nb - ob) & 0xFF)
        oldpos += add
        new += copy
        extra += copy
        oldpos += seek
        ctrl += offtout(add) + offtout(len(copy)) + offtout(seek)
    bz_ctrl = bz2.compress(bytes(ctrl), 9)
    bz_diff = bz2.compress(bytes(diff), 9)
    bz_extra = bz2.compress(bytes(extra), 9)
    patch = (b"BSDIFF40" + offtout(len(bz_ctrl)) + offtout(len(bz_diff))
             + offtout(len(new)) + bz_ctrl + bz_diff + bz_extra)
    return bytes(new), patch


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.abspath(__file__))
    new, patch = build()
    rebuilt = reference_bspatch(OLD, patch)
    if rebuilt != new:
        raise SystemExit("reference bspatch did not rebuild new.bin")
    files = {"old.bin": OLD, "new.bin": new, "patch.bsdiff": patch}
    for name, data in files.items():
        with open(os.path.join(out, name), "wb") as fh:
            fh.write(data)
        print(name, len(data), hashlib.sha256(data).hexdigest())
    print("reference bspatch rebuild: OK")


if __name__ == "__main__":
    main()
