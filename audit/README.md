# Verification tooling

Everything under `audit/` exists to *prove* properties of the extension
rather than to ship in it: independence of the implementation from prior
MARC software, byte-exact regeneration of the generated tables, and the
differential fuzz corpus.  Python lives here and nowhere else in the
repository; none of it is part of the build, and the DuckDB community
build ignores this directory entirely.

This file is the index and the run instructions.  Where an artifact came
from and why it can be trusted is `PROVENANCE.md`'s subject, and is not
retold here.

## Documents

| file | what it holds |
|---|---|
| `PROVENANCE.md` | the source and method behind every generated artifact, the specifications consulted for each hand-written subsystem, and the three lines of verification evidence |
| `SIMILARITY.md` | quantitative similarity of the generated tables, protocol code, call-number parser and Avram schemas against prior MARC software (pymarc, MARC::Charset, MARC4J, YAZ, library-callnumber-lc, GBV Avram), with methodology, calibration anchors and scores |
| `XSLT-DISTINCTNESS.md` | the same methodology applied to the crosswalk library against MarcEdit's and LC's published stylesheets |

## Tools (`tools/`)

| script | purpose |
|---|---|
| `gen_fuzz_cases.py` | deterministic generator of the 500-case differential corpus committed at `test/data/fuzz/` (requires `pip install pymarc`) |
| `gen_marc8_tables.py` | regenerates `src/include/marc/marc8_tables.hpp` from `data/codetables.xml`, and the Python companion's table with `--pytable` |
| `gen_unicode_tables.py` | regenerates `src/include/marc/unicode_tables.hpp` from UCD 14.0.0 |
| `marc8_oracle.py` | an independent MARC-8 decoder — the oracle the fuzz corpus is measured against |
| `similarity_check.py` | token 5-shingle, rare-shingle Jaccard comparison of source files against reference implementations |
| `xslt_distinctness.py` | the XSLT variant of the above, over normalised stylesheet token streams |

## Running the checks

Run everything from the repository root.

Both table generators have a `--check` mode that regenerates the header
and byte-compares it against the committed copy, exiting nonzero on any
difference:

```sh
python3 audit/tools/gen_marc8_tables.py --check src/include/marc/marc8_tables.hpp
python3 audit/tools/gen_unicode_tables.py --from-unicodedata \
    --check src/include/marc/unicode_tables.hpp
```

`gen_marc8_tables.py` reads `audit/data/codetables.xml` by default;
`--xml` points at a fresher download when LC updates the file.
`gen_unicode_tables.py` takes either `--from-unicodedata` (accepted only
when the running Python carries exactly UCD 14.0.0) or `--ucd-dir DIR`
holding `UnicodeData.txt` and `CompositionExclusions.txt` from that
version; the UCD files are not committed.

Replaying the differential fuzz corpus needs nothing but a compiler;
regenerating it needs pymarc:

```sh
make fuzz_check                                   # replay the committed corpus
pip install pymarc                                # only to regenerate
python3 audit/tools/gen_fuzz_cases.py test/data/fuzz
```

The two similarity reports are refreshed against reference corpora cloned
at check time and never committed; each report's own "Reproduction"
section carries the clone list and the exact command.

## Benchmarks

Timing comparisons are not kept here. They live with the Python companion,
alongside the reference implementation they measure, because a benchmark
harness is not part of what this extension ships.
