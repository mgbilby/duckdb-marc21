#!/usr/bin/env python3
"""Independent Python reference for MARC-8 decoding (`marc8_to_unicode`).

Used by tools/gen_fuzz_cases.py to produce the expected outputs that
test/cpp/fuzz_check.cpp replays against marc::Marc8Decode.  The point of
this file is DIFFERENTIAL verification: the decode logic below is written
in Python from the LC MARC-8 specification
(https://www.loc.gov/marc/specifications/speccharmarc8.html), and the
character mapping comes from pymarc's independently maintained
`marc8_mapping` tables (BSD-2-Clause; used at generation time only —
nothing from pymarc is copied into this repository or into the corpus
inputs).  The C++ decoder's tables were generated from LC's public-domain
codetables.xml, so table bugs on either side surface as mismatches.

Semantics implemented (the same spec-defined behaviour the C++ decoder
documents in src/core/marc8.cpp):
  * default G0 = Basic Latin (42), G1 = ANSEL (45);
  * ESC [I...] F designation, including multibyte '$' forms and the
    single-character technique-1 escapes g/b/p/s;
  * bytes < 0x21 and 0x7F pass through; 0x80-0xA0 and 0xFF -> U+FFFD;
  * EACC consumes three bytes, each masked to 7 bits;
  * combining marks precede their base in MARC-8 and are re-ordered to
    follow it; the result is NFC-normalised;
  * unmappable input -> U+FFFD; LC "maps to nothing" entries emit nothing.

Table adjustments applied on load (documented divergences, see
docs/audit/SIMILARITY.md):
  * pymarc keys some G1-oriented sets with the high bit set; keys are
    canonicalised to 7 bits;
  * for the four ANSEL ligature/double-tilde half characters (EB, EC, FA,
    FB) pymarc uses LC's *alternative* mapping (U+FE20..U+FE23); LC's
    primary column maps EB->U+0361, FA->U+0360 and the second halves to
    nothing, and that primary reading is restored here.

Requires pymarc importable (pip install pymarc, or a checkout on
sys.path).  Python 3.8+, standard library otherwise.
"""

import unicodedata

try:
    from pymarc import marc8_mapping
except ImportError as exc:  # pragma: no cover
    raise SystemExit(
        "marcref.py needs pymarc's marc8_mapping tables: pip install pymarc "
        "or add a pymarc checkout to PYTHONPATH"
    ) from exc

BASIC_LATIN = 0x42
ANSEL = 0x45
EACC = 0x31
REPLACEMENT = "�"

# LC codetables.xml primary mappings for the ANSEL two-half diacritics,
# where pymarc's tables carry LC's <alt> values instead.  None = LC
# "maps to nothing" (the second half is subsumed by the first).
ANSEL_PRIMARY_HALVES = {
    0x6B: (0x0361, 1),  # EB ligature, first half -> COMBINING DOUBLE INVERTED BREVE
    0x6C: (None, 1),    # EC ligature, second half -> nothing
    0x7A: (0x0360, 1),  # FA double tilde, first half -> COMBINING DOUBLE TILDE
    0x7B: (None, 1),    # FB double tilde, second half -> nothing
}


def _load_tables():
    tables = {}
    for code, mapping in marc8_mapping.CODESETS.items():
        if code == EACC:
            tables[code] = dict(mapping)  # 24-bit keys, kept as-is
        else:
            tables[code] = {k & 0x7F: v for k, v in mapping.items()}
    for k, v in ANSEL_PRIMARY_HALVES.items():
        tables[ANSEL][k] = v
    return tables


TABLES = _load_tables()


def marc8_to_unicode(data: bytes) -> str:
    """Decode MARC-8 bytes to an NFC-normalised string; never raises."""
    out = []
    pending = []  # combining marks waiting for their base character
    g0, g1 = BASIC_LATIN, ANSEL

    def emit(ch, combining=False):
        if ch is None:
            return  # LC "maps to nothing"
        if combining:
            pending.append(ch)
        else:
            out.append(ch)
            out.extend(pending)
            del pending[:]

    def emit_entry(entry):
        if entry is None:
            emit(REPLACEMENT)
        else:
            ucs, combining = entry
            if ucs == 0 or ucs is None:
                return  # LC "maps to nothing"
            emit(chr(ucs), bool(combining))

    i, n = 0, len(data)
    while i < n:
        b = data[i]

        if b == 0x1B:  # designation escape
            j = i + 1
            target_g1 = False
            if j < n and data[j] in (0x28, 0x2C):  # '(' ','
                j += 1
            elif j < n and data[j] in (0x29, 0x2D):  # ')' '-'
                target_g1 = True
                j += 1
            elif j < n and data[j] == 0x24:  # '$' multibyte forms
                j += 1
                if j < n and data[j] in (0x29, 0x2D):
                    target_g1 = True
                    j += 1
                elif j < n and data[j] == 0x2C:
                    j += 1
            elif j < n and data[j] in (0x67, 0x62, 0x70, 0x73):  # g b p s
                g0 = BASIC_LATIN if data[j] == 0x73 else data[j]
                i = j + 1
                continue
            else:
                emit(REPLACEMENT)
                i = j + 1 if j < n else n
                continue
            fin = data[j] if j < n else None
            if fin in TABLES:
                if target_g1:
                    g1 = fin
                else:
                    g0 = fin
            else:
                emit(REPLACEMENT)
            i = j + 1 if j < n else n
            continue

        if b < 0x21 or b == 0x7F:  # space and controls pass through
            emit(chr(b))
            i += 1
            continue

        setcode = g0 if b < 0x80 else g1
        if 0x80 <= b < 0xA1 or b == 0xFF:
            emit(REPLACEMENT)
            i += 1
            continue

        if setcode == EACC:  # three bytes, each masked to 7 bits
            if i + 2 < n:
                key, valid = 0, True
                for k in range(3):
                    mb = data[i + k] & 0x7F
                    valid = valid and 0x21 <= mb <= 0x7E
                    key = (key << 8) | mb
                emit_entry(TABLES[EACC].get(key) if valid else None)
                i += 3
            else:
                emit(REPLACEMENT)
                i = n
            continue

        if setcode == BASIC_LATIN and b < 0x80:  # identity
            emit(chr(b))
            i += 1
            continue

        emit_entry(TABLES[setcode].get(b & 0x7F))
        i += 1

    out.extend(pending)  # dangling diacritics at end of string are kept
    return unicodedata.normalize("NFC", "".join(out))


if __name__ == "__main__":
    import sys

    raw = sys.stdin.buffer.read()
    sys.stdout.write(marc8_to_unicode(raw))
