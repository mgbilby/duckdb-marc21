#!/usr/bin/env python3
"""Generate the differential fuzz corpus replayed by test/cpp/fuzz_check.cpp.

Writes two files (default test/data/fuzz/in.bin and expected.txt):
  * in.bin       -- MARC-8 byte-string cases;
  * expected.txt -- the decoding of each case per marc8_oracle.py, the
                    independent Python reference implementation.

`make fuzz_check` then replays the corpus through the C++ decoder
(marc::Marc8Decode) and fails on any disagreement.

File format (defined by fuzz_check.cpp): cases joined by "\n---\n"; within
a case, backslash and newline are backslash-escaped.

Generation is deterministic (fixed seed).  Case mix: plain ASCII, random
ANSEL/G1 bytes, diacritic+base pairs, designation escapes to every LC set
(including EACC in G0 and G1 and the technique-1 g/b/p/s escapes),
hostile input (truncated escapes, unknown finals, 0x80-0xA0, 0xFF,
truncated EACC triples, dangling diacritics), and pure random bytes.

Excluded by construction: the 13 EACC code points and 4 ANSEL half
characters where LC's codetables.xml lists both a primary and an
alternative Unicode mapping and existing implementations disagree (see
docs/audit/SIMILARITY.md).  marc8_oracle.py pins the ANSEL halves to LC's
primary column, so those ARE exercised; the ambiguous EACC points are
skipped (any case whose decode would touch one is regenerated).

Requires pymarc importable at generation time only (see marc8_oracle.py).
"""

import argparse
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import marc8_oracle as oracle  # noqa: E402

# EACC code points where pymarc carries LC's alternative mapping and the
# generated C++ table carries LC's primary column (see the audit doc).
AMBIGUOUS_EACC = {
    0x214339, 0x215061, 0x215C32, 0x215F71, 0x217559, 0x222A34, 0x223339,
    0x4B333E, 0x4B4B3E, 0x4B5F58, 0x4B7421, 0x6F7625, 0x6F773C,
}

SETS_1BYTE = [0x42, 0x45, 0x67, 0x62, 0x70, 0x32, 0x4E, 0x51, 0x33, 0x34, 0x53]
EACC_KEYS = sorted(k for k in oracle.TABLES[0x31] if k not in AMBIGUOUS_EACC)
ANSEL_COMBINING = [k | 0x80 for k, v in oracle.TABLES[0x45].items() if v[1] and v[0]]


def esc_to(rng, code, g1=False):
    if code == 0x31:  # EACC needs a multibyte designation
        inter = rng.choice([b"$)", b"$-"]) if g1 else rng.choice([b"$", b"$,"])
    else:
        inter = rng.choice([b")", b"-"]) if g1 else rng.choice([b"(", b","])
    return b"\x1b" + inter + bytes([code])


def eacc_bytes(rng, count, high=False):
    out = bytearray()
    for _ in range(count):
        key = rng.choice(EACC_KEYS)
        trip = [(key >> 16) & 0xFF, (key >> 8) & 0xFF, key & 0xFF]
        out += bytes(t | 0x80 for t in trip) if high else bytes(trip)
    return bytes(out)


def ascii_run(rng, lo=1, hi=12):
    return bytes(rng.choice(range(0x21, 0x7F)) for _ in range(rng.randint(lo, hi)))


def make_case(rng):
    kind = rng.randrange(10)
    if kind == 0:  # plain ASCII, spaces, controls
        return bytes(rng.choice(b"ABC xyz,.\t\r0129~") for _ in range(rng.randint(0, 24)))
    if kind == 1:  # raw G1 (default ANSEL) bytes
        return bytes(rng.choice(range(0xA1, 0xFF)) for _ in range(rng.randint(1, 16)))
    if kind == 2:  # diacritic(s) + base, the MARC-8 mark-before-base order
        out = bytearray()
        for _ in range(rng.randint(1, 5)):
            for _ in range(rng.randint(1, 3)):
                out.append(rng.choice(ANSEL_COMBINING))
            out += ascii_run(rng, 1, 3)
        return bytes(out)
    if kind == 3:  # designate a random set into G0 or G1, then text for it
        g1 = rng.random() < 0.5
        code = rng.choice(SETS_1BYTE)
        keys = [k for k, v in oracle.TABLES[code].items() if v[0]]
        body = bytes((rng.choice(keys) | (0x80 if g1 else 0)) for _ in range(rng.randint(1, 10)))
        return esc_to(rng, code, g1) + body + esc_to(rng, 0x42) + ascii_run(rng)
    if kind == 4:  # EACC in G0
        return esc_to(rng, 0x31) + eacc_bytes(rng, rng.randint(1, 5)) + b"\x1b(B" + ascii_run(rng)
    if kind == 5:  # EACC in G1 (high-bit bytes)
        return esc_to(rng, 0x31, g1=True) + eacc_bytes(rng, rng.randint(1, 5), high=True)
    if kind == 6:  # technique-1 escapes g/b/p/s
        out = bytearray()
        for _ in range(rng.randint(1, 4)):
            out += b"\x1b" + bytes([rng.choice(b"gbps")]) + ascii_run(rng, 1, 6)
        return bytes(out)
    if kind == 7:  # hostile: broken escapes, invalid highs, truncations
        menu = [
            b"\x1b", b"\x1b(", b"\x1b$", b"\x1b(Z", b"\x1b)\x00", b"\x1bQ",
            bytes([rng.randrange(0x80, 0xA1)]), b"\xff",
            esc_to(rng, 0x31) + eacc_bytes(rng, 1)[:rng.randint(1, 2)],
            bytes([rng.choice(ANSEL_COMBINING)]),  # dangling diacritic
        ]
        return b"".join(rng.choice(menu) for _ in range(rng.randint(1, 5)))
    if kind == 8:  # pure random bytes
        return bytes(rng.randrange(0, 256) for _ in range(rng.randint(1, 20)))
    # mixed: several of the above glued together
    return make_case(rng) + make_case(rng)


def touches_ambiguous(case):
    """Conservative filter: does this case contain an ambiguous EACC triple
    in either 7-bit or high-bit form?  (Byte-level scan; over-matching only
    costs a regenerated case.)"""
    masked = bytes(b & 0x7F for b in case)
    for key in AMBIGUOUS_EACC:
        trip = bytes([(key >> 16) & 0x7F, (key >> 8) & 0x7F, key & 0x7F])
        if trip in masked:
            return True
    return False


def escape(raw: bytes) -> bytes:
    return raw.replace(b"\\", b"\\\\").replace(b"\n", b"\\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--count", type=int, default=500)
    ap.add_argument("--seed", type=int, default=20260904)
    ap.add_argument("--out-dir", default="test/data/fuzz")
    args = ap.parse_args()

    rng = random.Random(args.seed)
    cases = []
    while len(cases) < args.count:
        case = make_case(rng)
        if touches_ambiguous(case):
            continue
        cases.append(case)

    os.makedirs(args.out_dir, exist_ok=True)
    sep = b"\n---\n"
    with open(os.path.join(args.out_dir, "in.bin"), "wb") as fh:
        fh.write(sep.join(escape(c) for c in cases))
    with open(os.path.join(args.out_dir, "expected.txt"), "wb") as fh:
        fh.write(sep.join(escape(oracle.marc8_to_unicode(c).encode("utf-8")) for c in cases))
    print("wrote {} cases to {}".format(len(cases), args.out_dir))


if __name__ == "__main__":
    main()
