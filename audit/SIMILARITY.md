# Similarity audit: duckdb-marc21 vs prior MARC software

Audited codebase: this repository's `src/`, `schemas/` and `test/` trees;
the tooling is `audit/tools/similarity_check.py`, and the report is
refreshed whenever a subsystem is substantially rewritten.
Purpose: respond to the external licensing audit's request for hard
evidence that this codebase was written from the published standards and
public-domain data, not copied or adapted from existing MARC software.
Related documents in this repository: `NOTICE` (licence
notices), `PROVENANCE.md` (how each artifact was produced and verified).

## 1. Methodology

### 1.1 Tool

`audit/tools/similarity_check.py` (committed; Python 3 standard library only)
computes five metrics per file pair, each in [0, 1]:

| metric | what it measures | what it catches |
|---|---|---|
| `seq_ratio` | `difflib.SequenceMatcher` over whitespace-normalised text | wholesale copying |
| `line_overlap` | fraction of A's distinct non-trivial lines (>= 12 significant chars) found verbatim in B | copied lines, even reordered |
| `tok_jaccard5` | Jaccard similarity of 5-token shingles of the lexed code (comments and string bodies removed) | copied code with changed formatting/comments |
| `ident_jaccard` | Jaccard similarity of identifier vocabularies (len >= 4, keywords excluded) | copied naming with rewritten logic |
| `comment_sh3` | Jaccard similarity of 3-word shingles of extracted comment prose | copied comments/documentation |

Reproduce any row with:

    python3 audit/tools/similarity_check.py <our file> <their file...>

(multiple comparison files are concatenated, so one translation unit can
be measured against a whole family, e.g. all of YAZ's `ber_*.c`), or
rerun every comparison and control in this report with:

    python3 audit/tools/similarity_check.py --audit \
        --repo /path/to/duckdb-marc21 --clones /path/to/clones

where `--clones` holds shallow clones named `pymarc`, `MARC-Charset`,
`marc4j`, `yaz`, `library-callnumber-lc`, and `avram-js` (§1.2 commits).

### 1.2 Comparison corpus (shallow clones, pinned commits)

| project | repository | commit |
|---|---|---|
| pymarc (Python) | github.com/edsu/pymarc | `cf33051421ac74389c1bc6d54921fb9612083d1b` |
| MARC::Charset (Perl) | github.com/gitpan/MARC-Charset | `484df683ef585cf744fd86a9108a1af7d9c0333a` |
| MARC4J (Java) | github.com/marc4j/marc4j | `6c6e7e442ca22c8cbc8df86042c169b73edb58ae` |
| YAZ (C, Z39.50/BER) | github.com/indexdata/yaz | `4ea0b8acc8cd1aed3a3b38b8c97fc094483c95b7` |
| library-callnumber-lc (Perl+Python) | github.com/libraryhackers/library-callnumber-lc | `5ce1d7ab5cca7533bad406f37cc3e718ac37c0fb` |
| avram-js incl. GBV MARC 21 schema (JS/JSON) | github.com/gbv/avram-js | `5dcd9351a814e08d7869711f8298635445753cf8` |

Clones were used read-only for measurement and are not part of this
repository.

### 1.3 Calibration

The metrics only mean something against known anchors, so three controls
were run:

| control | seq | line | tok5 | ident | comm3 |
|---|---|---|---|---|---|
| identity: `marc8.cpp` vs itself | 1.0000 | 1.0000 | 1.0000 | 1.0000 | 1.0000 |
| same-author templated siblings: YAZ `ber_bit.c` vs `ber_oct.c` | 0.7693 | 0.5676 | 0.5027 | 0.5600 | 0.5400 |
| independent implementations of the same spec: pymarc `marc8.py` vs MARC::Charset `Charset.pm` | 0.0248 | 0.0000 | 0.0024 | 0.0299 | 0.0076 |

Reading: files that share ancestry score in the 0.5-0.8 band even after
divergence; genuinely independent implementations of the *same
specification* score below ~0.03 everywhere, with `ident_jaccard` the
noisiest metric because the spec itself supplies shared vocabulary.  A
claim of independent authorship therefore predicts scores at or below
the third row.  That is what we find.

## 2. Results

### 2.1 MARC-8 tables and decoder

| comparison | seq | line | tok5 | ident | comm3 |
|---|---|---|---|---|---|
| `src/include/marc/marc8_tables.hpp` vs pymarc `marc8_mapping.py` | 0.0003 | 0.0000 | 0.0000 | 0.0000 | 0.0013 |
| `marc8_tables.hpp` vs MARC::Charset `Table.pm`+`Code.pm`+`Compiler.pm` | 0.0005 | 0.0000 | 0.0000 | 0.0115 | 0.0000 |
| `marc8_tables.hpp` vs MARC4J `CodeTable.java`+`CodeTableGenerator.java` | 0.0016 | 0.0000 | 0.0000 | 0.0081 | 0.0015 |
| `src/core/marc8.cpp` vs pymarc `marc8.py` | 0.0363 | 0.0000 | 0.0008 | 0.0149 | 0.0000 |
| `marc8.cpp` vs MARC::Charset `Charset.pm` | 0.0132 | 0.0000 | 0.0000 | 0.0078 | 0.0000 |
| `marc8.cpp` vs MARC4J `AnselToUnicode.java` | 0.0195 | 0.0000 | 0.0065 | 0.0252 | 0.0010 |

Structural comparison (things the numbers can't see):

* **Representation.** Ours: sorted constant C arrays of `{marc, ucs,
  combining}` triples per LC set, binary-searched, named
  `MARC8_SET_<final byte>`.  pymarc: Python dicts named `CHARSET_<hex>`
  with `(codepoint, combining)` tuples and an LC character *name comment
  on every line*.  MARC::Charset: no static table at all — a GDBM
  database compiled at install time from `codetables.xml`.  MARC4J: XML
  parsed into `HashMap`s (or generated Java) at build time.  Four
  different shapes; ours matches none of them.
* **The dog that didn't bark.** pymarc's table carries ~16,000 LC
  character-name comments.  Our generated header contains none — only
  set-level headings taken from LC's set names.  Scraping pymarc would
  have had to *remove* information that is effortless to keep.
* **Value-level cross-check** (this is verification evidence, not
  similarity evidence — both tables descend from LC's public-domain
  `codetables.xml`, so values *should* agree): after canonicalising
  pymarc's high-bit key convention, the two tables define an identical
  key universe for all 12 sets and agree on 16,376 of 16,398 mappings
  (99.87%).  Every one of the 22 differences is explained, and each
  explanation *supports* independent derivation from LC's file:
  * 5 control-range entries (0x1B, 0x1D-0x20 in Basic Latin) that
    pymarc stores as table rows; our decoder passes controls through in
    code, so the generator omits them.
  * 4 ANSEL double-diacritic halves (EB, EC, FA, FB): LC's
    `codetables.xml` gives primary `<ucs>` U+0361/U+0360 for the first
    halves, "maps to nothing" for the second halves, and U+FE20-U+FE23
    as `<alt>`.  Our table carries LC's **primary** column; pymarc
    carries the **alternates**.  Verified against the `codetables.xml`
    text shipped in MARC::Charset's `etc/`.
  * 13 EACC code points where pymarc deliberately substitutes LC's
    alternate mapping (its own comment: "I've picked the second");
    our table again carries LC's primary column.
  If our table had been converted from pymarc's, it would reproduce
  pymarc's choices; instead it consistently sides with LC's file
  against pymarc wherever the two diverge.

### 2.2 Z39.50 / BER client

| comparison | seq | line | tok5 | ident | comm3 |
|---|---|---|---|---|---|
| `src/core/z3950.cpp` vs YAZ `ber_any/bit/bool/int/len/null/oct/oid/tag.c` | 0.0110 | 0.0000 | 0.0067 | 0.0089 | 0.0008 |
| `z3950.cpp` vs YAZ `odr.c`+`odr_cons/seq/tag/oid/int/util.c` | 0.0115 | 0.0000 | 0.0066 | 0.0095 | 0.0009 |

Shared identifiers are limited to spec vocabulary (`bits`,
`constructed`, `next`, `size`, `type`).  Architecturally the two are
unrelated: YAZ's ODR is a bidirectional stream codec with arena
allocation driven by generated per-APDU functions (`z_*.c` produced by
`yaz-asncomp` from ASN.1 sources); ours is a hand-written
`std::string`-returning TLV builder plus a cursor `Reader`, with the
five APDU layouts transcribed as documentation comments straight out of
Z39.50-1995 (each with a stated confidence level — a tell of
transcription from the standard rather than from working code, which
would need no confidence notes).

### 2.3 Call numbers

| comparison | seq | line | tok5 | ident | comm3 |
|---|---|---|---|---|---|
| `src/core/callnum.cpp` vs Library::CallNumber::LC (`LC.pm`) | 0.0116 | 0.0000 | 0.0017 | 0.0121 | 0.0013 |
| `callnum.cpp` vs library-callnumber-lc Python (`callnumber/__init__.py`) | 0.0066 | 0.0000 | 0.0040 | 0.0247 | 0.0000 |

Design divergence: both prior libraries are regex-driven normalizers
(one large pattern, padded numeric fields joined by dots); ours is a
hand-rolled character-scanner grammar with a spaces/positional-decimal
sort-key layout (documented in the file header) that produces keys
incompatible with theirs by construction.  No regexes are used in
`callnum.cpp` at all.

### 2.4 Avram schemas

| comparison | seq | line | tok5 | ident | comm3 |
|---|---|---|---|---|---|
| `schemas/marc21_bibliographic.avram.json` vs GBV `avram-js` `test/schemas/marc21-bibliographic.json` | 0.0012 | 0.0000 | 0.0023 | 0.0000 | 0.0000 |

Token metrics are weak on JSON (string bodies are masked), so a
semantic comparison was run as well:

* Scope: ours defines 74 fields; GBV's 237.  All 74 appear in GBV's
  (unavoidable — both enumerate LC's tag list), but ours is an
  intentional "rulepack subset" with editorial annotations GBV lacks
  ("repeatable since the 2014 format update", the 1XX exclusivity note).
* Vocabulary: ours uses `description`, `required`, and no `positions`/
  `types`/`url`; GBV uses `label`, `url`, and rich `positions`/`types`
  blocks.  A copy would inherit `label` and the positions data.
* Field captions: only 47/74 name strings match GBV's, and the
  mismatches are systematic (ours spells LC's captions with spaced
  dashes and extra annotations; GBV uses LC's unspaced form, e.g.
  "Main Entry-Personal Name").
* One outright disagreement: tag 043 is non-repeatable in ours
  (current LC documentation) but repeatable in GBV's snapshot.
  Divergence on a fact is not something copying produces.

### 2.5 Whole-tree scan for third-party fingerprints

`grep -rniE 'copyright|\(c\) [0-9]|licen[sc]e|derived from|based on|adapted|courtesy'`
and scans for author names/emails/URLs of the compared projects
(`edsu`, `summers`, `indexdata`, `yaz`, `pymarc`, `marc4j`, `asl2@`,
CPAN/PyPI/GitHub URLs) over `src/`, `schemas/`, `test/`, `docs/` find:
no third-party copyright lines, no author names, no "derived from"
comments, and no project URLs.  The only matches are this project's own
wording (e.g. LC field caption "…Copyright Notice", DuckDB
`PermissionException` messages).

## 3. Conclusions

1. Every measured pair scores **at or below the independent-implementation
   baseline** (pymarc vs MARC::Charset), and far below the 0.5+ band that
   shared ancestry produces.  `line_overlap` is 0.0000 in every single
   comparison: not one non-trivial source line is shared with any of the
   six projects.
2. Structure, naming, comments, and architecture differ from each
   comparison target in ways that are hard to fake and easy to verify
   (section 2 narratives).
3. Where our data tables and third-party tables diverge, ours
   consistently match LC's primary published data, which is affirmative
   evidence for the stated provenance (generated from `codetables.xml`)
   rather than conversion from another library.
4. Honest limitations: (a) textual similarity cannot prove a negative —
   a from-memory paraphrase of code someone once read is undetectable
   by these metrics; the structural divergences and the differential
   test evidence in `PROVENANCE.md` are the mitigation.  (b) The
   comparison set covers the major open-source MARC-8 / Z39.50 /
   call-number / Avram implementations reachable on GitHub, not every
   MARC program ever written.  (c) The single-squash git history means
   authorship sequence cannot be replayed; this audit is the substitute
   evidence.

## 4. Reproduction

    # shallow-clone the §1.2 corpus into <clones>, check out the audited
    # commit of the repository into <repo>, then:
    python3 audit/tools/similarity_check.py --audit --repo <repo> --clones <clones>

    # or any single row, e.g.:
    python3 audit/tools/similarity_check.py \
        <repo>/src/core/z3950.cpp <clones>/yaz/src/ber_*.c

The differential fuzz corpus that the §2.1 cross-check complements is
described in `PROVENANCE.md`.
