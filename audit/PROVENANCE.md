# Provenance

What every non-trivial artifact in this repository was built from, what
was consulted while writing each subsystem, and how the results are
verified.  Licence notices for the derived data live in `NOTICE`; the
quantitative not-copied analysis in `SIMILARITY.md` and
`XSLT-DISTINCTNESS.md` beside this file; the tooling and the commands that
run it in `README.md`.

Ground rules followed throughout the project:

* **Specifications and public-domain data were used as sources.**
* **No code from other MARC software was copied, ported, or
  translated.**  Where third-party implementations are mentioned below
  they were used only as *black-box oracles* (feed input, compare
  output) at test-generation time; nothing from them ships in this
  repository.

## Generated artifacts

### `src/include/marc/marc8_tables.hpp`

* **Source data:** the Library of Congress MARC-8 to Unicode mapping
  file `codetables.xml`
  (https://www.loc.gov/marc/specifications/codetables.xml), part of the
  MARC 21 Character Sets specification.  US federal government work,
  public domain.  A verbatim copy is pinned at `audit/data/codetables.xml`
  so the check below is reproducible offline.
* **How:** `audit/tools/gen_marc8_tables.py` reads each `<characterSet>`
  and emits one sorted `{marc, ucs, combining}` array per set.  It keeps
  LC's primary `<ucs>` column; LC `<alt>` mappings are not used, and LC's
  explicit empty-`<ucs>` entries ("maps to nothing") are kept as
  `ucs = 0`.  The same generator emits the Python companion's table with
  `--pytable`, so both languages read one source, and its `--check` mode
  (README.md) holds the committed header to what it produces.
* **Verification:** a value-level cross-check against pymarc's
  independently maintained tables, reported in SIMILARITY.md §2.1, plus
  the differential fuzz corpus below.

### `src/include/marc/unicode_tables.hpp`

* **Source data:** the Unicode Character Database, version 14.0.0
  (canonical combining classes, canonical decompositions, primary
  composites).  Redistributed under the Unicode License v3 — see `NOTICE`.
* **How:** `audit/tools/gen_unicode_tables.py` derives the tables from
  the UCD 14.0.0 data files (`--ucd-dir`) or from Python's `unicodedata`
  module when it carries exactly UCD 14.0.0 (`--from-unicodedata`); both
  paths produce the identical header, which its `--check` mode
  (README.md) holds the committed copy to.
* **Verification:** all 912 `CCC_TABLE` entries match
  `unicodedata.combining()` under UCD 14.0.0 with zero mismatches and
  zero omissions across the whole code space; all 941 `COMP_TABLE` rows
  recompose correctly under `unicodedata.normalize("NFC")`; all 2,061
  `DECOMP_TABLE` rows match `unicodedata.normalize("NFD")`.

### `schemas/*.avram.json`

* **Written by hand for this project** (they are sources, not generated
  files) from the Library of Congress MARC 21 format documentation:
  Bibliographic, Authority, and Holdings
  (https://www.loc.gov/marc/bibliographic/ etc.).
* **Schema language:** the Avram specification published by GBV/VZG
  (https://format.gbv.de/schema/avram/specification), which is CC0.
  Only the *specification* was consulted; no Avram schema published by
  GBV or anyone else was copied (SIMILARITY.md §2.4 quantifies this —
  different key vocabulary, different scope, different caption
  spellings, and one deliberate factual divergence where GBV's snapshot
  lags current LC documentation).
* The larger inline rulepack in `src/macros.sql` has the same pedigree:
  written from LC documentation, with its self-declared limits recorded
  in its own `description` field.

## Hand-written subsystems: what was consulted

| subsystem | files | consulted while writing |
|---|---|---|
| Avram validation, catalog derivations, editing, linking | `avram.cpp`, `catalog.cpp`, `edit.cpp`, `authlink.cpp` | Avram spec; LC leader/006/007/008 value tables; RDA content/media/carrier vocabularies |
| Breaker/mnemonic text formats | `breaker.cpp`, `textwriters.cpp`, `aleph.cpp`, `microlif.cpp` | published format descriptions (LC MARCMaker mnemonics, Ex Libris Aleph sequential layout, MicroLIF) |
| Call numbers | `callnum.cpp` | the published structure of LC Classification and Dewey call numbers only; explicitly *no* external call-number library code (see the file header and SIMILARITY.md §2.3) |
| Clustering keys | `cluster.cpp` | OpenRefine's published descriptions of its key-collision and n-gram fingerprint methods (prose, not code) |
| Identifier normalisation | `idnorm.cpp` | ISBN/ISSN/LCCN check-digit rules from the ISO standards and LC's LCCN structure page |
| ISO 2709 reader/writer | `src/core/iso2709.cpp`, `writer.cpp` | ISO 2709 / ANSI Z39.2 record structure as documented in the LC MARC 21 specification |
| MARC-8 decoder | `src/core/marc8.cpp` | LC MARC 21 Specifications, Character Sets part (G0/G1 designation model, escape sequences, EACC) |
| MARCspec queries | `marcspec.cpp` | the public MARCspec description (marcspec.github.io) |
| MARCXML / MARC-in-JSON | `marcxml.cpp`, `marcjson.cpp`, `json.cpp` | LC MARCXML schema documentation; the MARC-in-JSON description used by modern tooling |
| Unicode NFC/NFD | `src/core/unicode_nfc.cpp` | UAX #15 (canonical ordering, composition algorithm), UCD data above |
| XSLT crosswalks | `xslt/*.xsl` | the target formats' own specifications (LC MODS/MADS/EAD3/BIBFRAME, DCMI, EDItEUR ONIX, Europeana EDM, IFLA UNIMARC, schema.org); per-file headers name each, `xslt/DISTINCTNESS.md` records them per stylesheet, and `XSLT-DISTINCTNESS.md` quantifies independence from MarcEdit's library |
| Z39.50 client | `z3950.cpp`, `z3950_socket.cpp` | ANSI/NISO Z39.50-1995 ASN.1 module and ITU-T X.690 BER; the file header transcribes every tag assignment relied on, each with a confidence note |

No GPL or other copyleft source was read as reference for any of the
above.  The permissively licensed implementations listed in
SIMILARITY.md were consulted only in the sense described next —
as differential oracles — with one exception: pymarc's mapping *tables*
are read at fuzz-corpus generation time (BSD-2-Clause, generation-time
only, nothing copied into the tree).

## Verification story

Three independent lines of evidence back the implementation:

1. **Differential fuzzing against an independent reference
   (`make fuzz_check`).**
   * `audit/tools/marc8_oracle.py` is a second MARC-8 decoder, written in
     Python from the LC specification, whose character mapping comes from
     pymarc's independently derived tables — so both the decode logic
     and the table data are independent of the C++ implementation.  That
     second half is the point: this extension's tables and the Python
     companion's reference decoder are both generated from the same LC
     file, so measuring one against the other would test two decoders
     over one set of data, and an error in the generated tables would
     agree with itself and pass.  Taking the mappings from an
     independently maintained source closes that gap, and the file is
     named for the job so it is not later folded into a reference
     implementation.  Nothing from pymarc ships here: it is imported
     while the corpus is generated, and what lands in the tree is the
     corpus.
   * `audit/tools/gen_fuzz_cases.py` deterministically generates 500
     cases (fixed seed): plain ASCII, raw ANSEL, mark-before-base
     sequences, designation escapes into every LC set including EACC in
     G0 and G1, technique-1 escapes, truncated/hostile input, and pure
     random bytes.  Expected outputs are the oracle's decodings.  The 13
     EACC code points where LC documents both a primary and an
     alternative mapping (and implementations legitimately differ) are
     excluded by construction and are instead covered by the
     table-level cross-check in SIMILARITY.md §2.1.
   * The corpus is committed under `test/data/fuzz/` (`in.bin`,
     `expected.txt`), and `make fuzz_check` compiles
     `test/cpp/fuzz_check.cpp` with the core sources
     (`g++ -std=c++17 -Wall -O2 -pthread -Isrc/include src/core/*.cpp
     test/cpp/fuzz_check.cpp`) and replays it; the harness fails
     (exit 1) on any mismatch.
   * Regenerating the corpus requires pymarc importable
     (`pip install pymarc`); running `make fuzz_check` requires nothing
     beyond g++.
2. **Round-trip and unit tests (`make core_test` and the other
   `test/cpp/*` suites).**  They exercise ISO 2709 parse/serialise
   round-trips, MARC-8 decoding edge cases, NFC/NFD normalisation,
   MARCXML/JSON round-trips, call-number parsing/sort-key ordering,
   identifier check digits, editing and linking operations, and the
   Z39.50 BER encoder/decoder against byte-exact APDU fixtures (including
   a scripted mock server for the socket layer).  The XSLT library has
   its own xsltproc runners under `test/xslt/`.
3. **Real-data agreement.**  The SQL-level tests under `test/sql` run
   the extension over genuine library records (`test/data`), and the
   MARC-8 value tables agree with pymarc's across an identical key
   universe to the degree SIMILARITY.md §2.1 quantifies, with every
   difference accounted for by LC's own primary/alternate columns — the
   level of agreement two honest derivations of the same public-domain
   file should show.

## Similarity audit

`audit/tools/similarity_check.py` and `audit/tools/xslt_distinctness.py`
produce the token-shingle comparisons reported in `SIMILARITY.md`
and `XSLT-DISTINCTNESS.md`.  Refresh both reports whenever a
subsystem is substantially rewritten; the git history is a squash, so
these reports, not the commit sequence, are the evidence of independent
authorship.
