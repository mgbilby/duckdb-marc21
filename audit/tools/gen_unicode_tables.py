#!/usr/bin/env python3
"""Regenerate the marc21 extension's NFC/NFD table header from Unicode data.

Emits the C++ header the extension compiles as
src/include/marc/unicode_tables.hpp, holding the three tables its UAX #15
normalizer (src/core/unicode_nfc.cpp) walks:

  * CCC_TABLE    -- every code point with a nonzero canonical combining
                    class, sorted by code point;
  * COMP_TABLE   -- the primary composites: canonical two-character
                    decompositions minus the composition exclusions
                    (the listed script-specifics, singleton decompositions,
                    and non-starter decompositions per UAX #15), sorted by
                    (first, second);
  * DECOMP_TABLE -- the FULL (recursive) canonical decomposition, in
                    canonical order, of every code point that has a
                    canonical decomposition mapping (Hangul is algorithmic
                    and deliberately absent), sorted by code point, at most
                    4 characters each.

Data sources, in order of preference:
  1. --ucd-dir DIR containing UnicodeData.txt and CompositionExclusions.txt
     from the Unicode Character Database, version 14.0.0 (the version the
     extension pins; see its NOTICE);
  2. --from-unicodedata: Python's own unicodedata module, accepted only
     when unicodedata.unidata_version is exactly 14.0.0 (CPython 3.11).
     The listed composition exclusions are derived behaviorally on this
     path: a starter pair decomposition whose NFC does not recompose to
     its composite is excluded -- exactly UAX #15's full exclusion set.

The emitted header's provenance comment is reproduced verbatim from the
committed header so that --check can demand byte identity.

Usage:
    gen_unicode_tables.py --ucd-dir DIR [-o OUT.hpp]
    gen_unicode_tables.py --from-unicodedata [-o OUT.hpp]
    gen_unicode_tables.py --ucd-dir DIR --check PATH/TO/unicode_tables.hpp

--check regenerates and byte-compares against the committed header, exiting
nonzero (with a diff summary) on any mismatch.
"""

import argparse
import difflib
import os
import sys

UCD_VERSION = "14.0.0"


def load_from_ucd(ucd_dir):
    """(ccc: {cp: int}, decomp: {cp: [cp...]}, listed_exclusions: set)."""
    ccc = {}
    decomp = {}
    path = os.path.join(ucd_dir, "UnicodeData.txt")
    with open(path, encoding="utf-8") as f:
        for line in f:
            fields = line.rstrip("\n").split(";")
            if len(fields) < 6:
                continue
            cp = int(fields[0], 16)
            klass = int(fields[3])
            if klass:
                ccc[cp] = klass
            dm = fields[5]
            if dm and not dm.startswith("<"):  # canonical mappings only
                decomp[cp] = [int(x, 16) for x in dm.split()]
    listed = set()
    path = os.path.join(ucd_dir, "CompositionExclusions.txt")
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            if ".." in line:
                lo, hi = line.split("..")
                listed.update(range(int(lo, 16), int(hi, 16) + 1))
            else:
                listed.add(int(line, 16))
    return ccc, decomp, listed


def load_from_unicodedata():
    import unicodedata
    if unicodedata.unidata_version != UCD_VERSION:
        sys.exit("error: this Python's unicodedata is UCD %s, need %s -- "
                 "use --ucd-dir instead" % (unicodedata.unidata_version, UCD_VERSION))
    ccc = {}
    decomp = {}
    for cp in range(0x110000):
        klass = unicodedata.combining(chr(cp))
        if klass:
            ccc[cp] = klass
        dm = unicodedata.decomposition(chr(cp))
        if dm and not dm.startswith("<"):
            decomp[cp] = [int(x, 16) for x in dm.split()]
    # Behavioral exclusion set: a composite whose NFD does not recompose to
    # it under NFC is composition-excluded (covers the listed
    # script-specifics; singletons and non-starters are filtered again in
    # build_tables, harmlessly).
    listed = set()
    for cp in decomp:
        nfd = unicodedata.normalize("NFD", chr(cp))
        if unicodedata.normalize("NFC", nfd) != chr(cp):
            listed.add(cp)
    return ccc, decomp, listed


def full_decomposition(cp, decomp, ccc):
    """Recursive canonical decomposition of cp, in canonical order."""
    out = []

    def expand(c):
        if c in decomp:
            for part in decomp[c]:
                expand(part)
        else:
            out.append(c)

    expand(cp)
    # Canonical Ordering Algorithm: stable bubble of adjacent non-starters
    # whose combining classes are out of order.
    changed = True
    while changed:
        changed = False
        for i in range(len(out) - 1):
            a, b = ccc.get(out[i], 0), ccc.get(out[i + 1], 0)
            if b != 0 and a > b:
                out[i], out[i + 1] = out[i + 1], out[i]
                changed = True
    return out


def build_tables(ccc, decomp, listed):
    ccc_rows = sorted(ccc.items())

    comp_rows = []
    for cp, seq in decomp.items():
        if len(seq) != 2 or cp in listed:
            continue
        if ccc.get(cp, 0) != 0 or ccc.get(seq[0], 0) != 0:  # non-starter decomposition
            continue
        comp_rows.append((seq[0], seq[1], cp))
    comp_rows.sort()

    decomp_rows = []
    for cp in sorted(decomp):
        seq = full_decomposition(cp, decomp, ccc)
        if len(seq) > 4:
            sys.exit("error: decomposition of U+%04X longer than 4" % cp)
        decomp_rows.append((cp, seq))
    return ccc_rows, comp_rows, decomp_rows


def render(ccc_rows, comp_rows, decomp_rows):
    out = []
    out.append("// GENERATED by tools/gen_unicode_tables.py from the Unicode data in")
    out.append("// Python's unicodedata module (UCD %s). Do not edit; regenerate." % UCD_VERSION)
    out.append("#pragma once")
    out.append("#include <cstdint>")
    out.append("namespace marc {")
    out.append("struct CccEntry { char32_t cp; uint8_t ccc; };")
    out.append("struct CompEntry { char32_t first; char32_t second; char32_t composed; };")
    out.append("struct DecompEntry { char32_t cp; uint8_t len; char32_t seq[4]; };")
    out.append("inline constexpr CccEntry CCC_TABLE[%d] = {" % len(ccc_rows))
    out.append(",".join("{0x%X,%d}" % (cp, k) for cp, k in ccc_rows))
    out.append("};")
    out.append("inline constexpr CompEntry COMP_TABLE[%d] = {" % len(comp_rows))
    out.append(",".join("{0x%X,0x%X,0x%X}" % row for row in comp_rows))
    out.append("};")
    out.append("inline constexpr DecompEntry DECOMP_TABLE[%d] = {" % len(decomp_rows))
    out.append(",".join(
        "{0x%X,%d,{%s}}" % (cp, len(seq),
                            ",".join("0x%X" % c for c in (seq + [0] * 4)[:4]))
        for cp, seq in decomp_rows))
    out.append("};")
    out.append("} // namespace marc")
    return "\n".join(out) + "\n"


def cross_verify(decomp_rows):
    """When this Python's unicodedata matches, demand NFD agreement."""
    import unicodedata
    if unicodedata.unidata_version != UCD_VERSION:
        return "skipped (unicodedata is UCD %s)" % unicodedata.unidata_version
    for cp, seq in decomp_rows:
        want = [ord(c) for c in unicodedata.normalize("NFD", chr(cp))]
        if want != seq:
            sys.exit("error: DECOMP row U+%04X = %s but unicodedata NFD says %s"
                     % (cp, ["%04X" % c for c in seq], ["%04X" % c for c in want]))
    return "all %d DECOMP rows agree with unicodedata NFD" % len(decomp_rows)


def check(generated, against_path):
    with open(against_path, "rb") as f:
        committed = f.read()
    if generated.encode("utf-8") == committed:
        print("OK: generated header is byte-identical to %s" % against_path)
        return 0
    print("MISMATCH: generated header differs from %s" % against_path, file=sys.stderr)
    gen_lines = generated.splitlines(keepends=True)
    com_lines = committed.decode("utf-8", "replace").splitlines(keepends=True)
    for line in difflib.unified_diff(com_lines, gen_lines, fromfile=against_path,
                                     tofile="<generated>", n=0):
        sys.stderr.write(line if len(line) < 400 else line[:400] + " ...[truncated]\n")
    return 1


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--ucd-dir", help="directory with UnicodeData.txt + "
                     "CompositionExclusions.txt (UCD %s)" % UCD_VERSION)
    src.add_argument("--from-unicodedata", action="store_true",
                     help="derive from Python's unicodedata (must be UCD %s)" % UCD_VERSION)
    ap.add_argument("-o", "--output", help="write the header here (default: stdout)")
    ap.add_argument("--check", metavar="HEADER",
                    help="byte-compare against this committed unicode_tables.hpp; "
                         "exit 1 on mismatch")
    args = ap.parse_args()

    if args.ucd_dir:
        ccc, decomp, listed = load_from_ucd(args.ucd_dir)
    else:
        ccc, decomp, listed = load_from_unicodedata()
    ccc_rows, comp_rows, decomp_rows = build_tables(ccc, decomp, listed)
    print("cross-verify: %s" % cross_verify(decomp_rows), file=sys.stderr)
    generated = render(ccc_rows, comp_rows, decomp_rows)
    if args.check:
        sys.exit(check(generated, args.check))
    if args.output:
        with open(args.output, "w", encoding="utf-8", newline="\n") as f:
            f.write(generated)
    else:
        sys.stdout.write(generated)


if __name__ == "__main__":
    main()
