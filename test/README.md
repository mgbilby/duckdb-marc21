# Test suite

Everything here runs locally; nothing in the suite depends on hosted CI.
The platform matrix (Linux, macOS, Windows, WASM) is the distribution
pipeline's job, and the DuckDB community build runs on its own
infrastructure — a green local run is the gate before a release.

Ubuntu prerequisites:

```sh
sudo apt install build-essential cmake ninja-build python3 xsltproc libxml2-utils yaz
```

## Layout

| path | what it holds |
|---|---|
| `test/cpp/` | 12 standalone suites over `src/core/` plus `fuzz_check`, each a single translation unit compiled with `g++`, no DuckDB needed |
| `test/data/` | committed fixtures — small, hand-built, and readable; `edge/`, `fuzz/`, `bibframe/`, `intl/`, `xslt/` group them by suite |
| `test/sql/` | 39 sqllogictest files — the SQL surface end to end, run by DuckDB's `unittest` |
| `test/xslt/` | `run.sh` for the crosswalk library, with `bibframe/` and `intl/` runners of their own; assertions are `xsltproc` transforms checked with `grep` and `xmllint` |

## Running

```sh
# full build, then the SQL suite (960 assertions, 36 cases; 3 skip without the json extension)
GEN=ninja make release
./build/release/test/unittest --test-dir . "test/sql/*"

# standalone core suites and the differential fuzz replay (500 cases)
make core_test && make fuzz_check
for t in edit cluster microlif nfd catalog authlink; do
    g++ -std=c++17 -Wall -O2 -pthread -Isrc/include src/core/*.cpp test/cpp/${t}_test.cpp -o build/${t}_test && ./build/${t}_test
done

# crosswalk assertions (190 / 68 / 154 checks)
bash test/xslt/run.sh && bash test/xslt/bibframe/run.sh && bash test/xslt/intl/run.sh

# generated tables still match their generators, byte for byte
python3 audit/tools/gen_marc8_tables.py --check src/include/marc/marc8_tables.hpp
python3 audit/tools/gen_unicode_tables.py --from-unicodedata --check src/include/marc/unicode_tables.hpp
```

Macro files under `src/macros/*.sql` and the stylesheets are embedded at
CMake configure time, so `touch CMakeLists.txt` before `ninja` after editing
them. A configuration change (`extension_config.cmake`, the extension list)
needs `rm -rf build` — `make clean` leaves `CMakeCache.txt` in place and the
stale list is reused, which makes the edit look like it did nothing.

## Fixtures and real data

The committed fixtures are deliberately tiny: they pin exact semantics
(escape sequences, a lying leader, an 880 pair, an empty subfield) and stay
readable in a diff. They say nothing about how the extension behaves on a
few million real records, which is what the corpora below are for.

Downloaded corpora live in `~/marcdata`, outside the repository — there is
nothing to ignore and no way to commit them by accident. Each is public,
but they range from tens of megabytes to several gigabytes, and their
licences are the providers' to state. DuckDB expands `~` when it opens a
file, so `read_marc('~/marcdata/...')` works as written, inside SQL as well
as at the shell.

| Data source | URL | Filename | Recipes |
| --- | --- | --- | --- |
| Cambridge Core KBART | `https://www.cambridge.org/core/services/librarians/kbart` | `Cambridge_Journals_Gold_OA.txt` | 1 — ISSN → 022 branch |
| DOAB / OAPEN KBART export | `https://www.doabooks.org/` · `https://www.oapen.org/` | `doab_kbart.txt` | 1 |
| Duke University Press KBART | `https://www.dukeupress.edu/Information-For/Librarians/Account-Administration/Title-List` | `Duke_University_Press_AlleDukeBooks.txt` | 1 — ISBN → 020 branch |
| id.loc.gov — current NAF records | `https://id.loc.gov/authorities/names/` | `n79021164.marcxml.xml` | 4 (second snapshot for the diff) |
| LC Books, 2016 retrospective | `https://archive.org/download/marc_loc_2016/` | `BooksAll.2016.part01.utf8` | 5, 6, 7 |
| MDSConnect — LC Name Authorities | `https://www.loc.gov/cds/products/marcDist.php` | `Names.2016.part01.utf8` | 3, 4 |
| Met / Watson Library record sets | `https://www.metmuseum.org/departments/thomas-j-watson-library/library-resources/marc-record-sets-created-by-watson-library` | `AAAP-PDF_records_2024-03.zip` | 5, 2 |
| Scriblio MARC donation | `https://archive.org/details/marc_records_scriblio_net` | `part01.dat` | 5, 6, 7 — second file for cross-file globbing |
| yaz-marcdump | `sudo apt install yaz` | n/a | all — round-trip check on `FORMAT marc` output |

The recipe numbers are the sections of [docs/RECIPES.md](../docs/RECIPES.md).
Run each recipe against the corpus its row names, and check three things:
the recipe completes, its counts are plausible for the corpus, and records
written back survive the round trip.

The round trip is the sharpest of those checks, because it uses an
independent parser rather than this one:

```sh
# write records out, then read them with a parser that is not ours
./build/release/duckdb -c "LOAD marc21;
    COPY (SELECT leader, fields FROM read_marc('~/marcdata/BooksAll.2016.part01.utf8'))
    TO '~/marcdata/roundtrip.mrc' (FORMAT marc);"
yaz-marcdump ~/marcdata/roundtrip.mrc > /dev/null   # silence means well-formed ISO 2709
```

`yaz-marcdump` reports leader, directory and field-length faults that our
own reader would accept, so it catches writer bugs the SQL suite cannot.

Silence is weaker evidence than it looks: an empty output file passes it
too, and so does one good record where there should be a quarter million.
Four more checks make the round trip actually verified.

**1. Counts, from outside and inside.** ISO 2709 records end with `0x1D`, so
the shell can count them without trusting either parser:

```sh
tr -cd '\035' < ~/marcdata/BooksAll.2016.part01.utf8 | wc -c
tr -cd '\035' < ~/marcdata/roundtrip.mrc | wc -c
./build/release/duckdb -c "LOAD marc21;
    SELECT (SELECT count(*) FROM read_marc('~/marcdata/BooksAll.2016.part01.utf8')) AS src,
           (SELECT count(*) FROM read_marc('~/marcdata/roundtrip.mrc')) AS rt;"
```

All four equal. A reader count below the terminator count means records
failed to parse and never reached the output.

**2. Content, subfield by subfield**, both directions:

```sh
./build/release/duckdb -c "LOAD marc21;
WITH a AS (SELECT record_no, control_number, field_no, tag, ind1, ind2, subfield_no, code, value
           FROM read_marc_subfields('~/marcdata/BooksAll.2016.part01.utf8')),
     b AS (SELECT record_no, control_number, field_no, tag, ind1, ind2, subfield_no, code, value
           FROM read_marc_subfields('~/marcdata/roundtrip.mrc'))
SELECT (SELECT count(*) FROM (SELECT * FROM a EXCEPT ALL SELECT * FROM b)) AS lost,
       (SELECT count(*) FROM (SELECT * FROM b EXCEPT ALL SELECT * FROM a)) AS gained;"
```

Both zero. Exclude `file` (the paths differ) and `leader` (the writer
recomputes length and base address).

**3. Structure.** Equal field counts prove the directory is the same size in
both, so nothing was dropped:

```sh
./build/release/duckdb -c "LOAD marc21;
WITH a AS (SELECT record_no, len(fields) AS nf FROM read_marc('~/marcdata/BooksAll.2016.part01.utf8')),
     b AS (SELECT record_no, len(fields) AS nf FROM read_marc('~/marcdata/roundtrip.mrc'))
SELECT count(*) FILTER (WHERE a.nf <> b.nf) AS differing, sum(a.nf - b.nf) AS fields_lost
FROM a JOIN b USING (record_no);"
```

**4. Account for every byte.** The files will not be the same size. Confirm
the difference lives inside records and nowhere else:

```sh
./build/release/duckdb -c "LOAD marc21;
WITH a AS (SELECT record_no, octet_length(raw) AS n FROM read_marc_raw('~/marcdata/BooksAll.2016.part01.utf8')),
     b AS (SELECT record_no, octet_length(raw) AS n FROM read_marc_raw('~/marcdata/roundtrip.mrc'))
SELECT count(*) AS records, count(*) FILTER (WHERE a.n <> b.n) AS differing,
       sum(a.n - b.n) AS total_shrink, min(a.n - b.n) AS min_delta, max(a.n - b.n) AS max_delta
FROM a JOIN b USING (record_no);"
```

`total_shrink` should equal the `ls -l` difference exactly.

### Why cmp fails, and why that is correct

`cmp` will report a difference, and should. Readers return NFC; LC's files
are NFD. Every `e` + combining acute comes back as `é`, one byte shorter, so
a decomposed source shrinks by one byte per composed character. Over
BooksAll part 01 that is 697,697 bytes across 100,676 of 250,000 records,
with no subfield lost — the deltas decay smoothly from one byte upward as
records carry more diacritics.

Note the trap in checks 2 and 3: they read both files through the same
reader, so they cannot see anything that reader normalizes. Only raw bytes
can. To identify a difference rather than assume it, take the byte
histogram of one record from each file:

```sh
for f in ~/marcdata/BooksAll.2016.part01.utf8 ~/marcdata/roundtrip.mrc; do
  ./build/release/duckdb -noheader -list -c "LOAD marc21;
      SELECT hex(raw) FROM read_marc_raw('$f') WHERE record_no = 76852;" | tr -d '\n' |
    fold -w2 | sort | uniq -c | sort -rn > "/tmp/$(basename $f).hist"
done
diff /tmp/*.hist
```

`CC` and `CD` lead bytes on one side (combining marks) against `C4`, `C5`
and `E1` on the other (precomposed Latin Extended) is normalization. Equal
counts of `20` rule out whitespace trimming. Missing field terminators
(`1E`) or subfield delimiters (`1F`) would be a real defect.
