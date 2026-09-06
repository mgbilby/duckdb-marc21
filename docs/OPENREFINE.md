# marc21 × OpenRefine: interoperability guide

OpenRefine and this extension sit on opposite sides of the same cleanup
problems. OpenRefine is interactive: facets, per-cell judgment, an undo
history, a human deciding each merge. marc21 is corpus-scale SQL: headless,
set-based, repeatable, happy at millions of records. Neither should imitate
the other — the extension does not rebuild a faceting UI, and OpenRefine is
not a join engine — so the useful question is how to move work between them
with nothing lost in transit. Three bridges carry all of it:

1. **shared clustering vocabulary** — `marc_fingerprint` and
   `marc_ngram_fingerprint` compute the same key-collision keys OpenRefine's
   "Cluster and edit" describes, so a clustering decision made in either tool
   transfers to the other (§2);
2. **the one-row-per-subfield shape** — `read_marc_subfields` output *is* an
   OpenRefine project waiting to happen, and TSV carries it both ways (§3);
3. **reconciliation** — OpenRefine's Reconciliation Service API and the
   extension's `marc_reconcile_headings` queue address the same job from the
   interactive and batch ends (§4).

There is also a division of labor OpenRefine cannot avoid: it does not read
ISO 2709. The extension is the on-ramp and off-ramp — binary MARC (any
encoding, gzipped, globbed) in through `read_marc`, refined data back out
through `COPY (FORMAT marc)`. Per the doctrine in
[ECOSYSTEM.md](ECOSYSTEM.md), everything below composes stock DuckDB with the
extension's MARC semantics; no OpenRefine feature is reimplemented here.

## 1. Why they pair well

The typical loop: profile and extract in SQL (`marc_summary_subfields`,
`read_marc_subfields` with a `WHERE`), hand the *interesting subset* — never
the whole corpus — to OpenRefine for eyes-on refinement, then pull the
refined column back and apply it to the full files with the editing macros.
SQL finds the 3,000 suspect headings among 5 million; OpenRefine is where a
person approves each fix; SQL writes the fixes into the records.

The clustering keys make the loop honest in both directions: you can compute
in SQL exactly which values OpenRefine's key-collision clustering *would*
group — sizing the interactive job before opening it — and you can re-apply
an OpenRefine clustering decision across files that were never loaded into
the project.

## 2. Matching clustering keys

`marc_fingerprint(v)` and `marc_ngram_fingerprint(v, n)` were implemented
from OpenRefine's openly published algorithm descriptions (the "Clustering
In Depth" write-up) with no OpenRefine code consulted: fix whitespace,
lowercase, remove punctuation and control characters, normalize extended
western characters to ASCII, then split/sort/de-dupe/re-join on spaces
(fingerprint) or take the sorted unique n-grams of the space-less text,
concatenated (n-gram fingerprint). For ordinary Latin-script headings the
keys — and therefore the clusters — line up between the two tools:
`marc_fingerprint` keys `Cruise, Tom`, `  Tom Cruise  ` and `CRUISE tom!!`
all as `cruise tom`, exactly as OpenRefine's fingerprint keyer does.

### Where a key here can differ from OpenRefine's

The character normalization is the extension's NACO folding engine
(`marc_naco`'s, kept single-sourced on purpose), and the implementation
follows the published *description* rather than OpenRefine's code. The
deviations are deliberate and documented in `src/core/cluster.cpp`; this is
the exhaustive list of cases where the two tools can disagree about a key:

| case | this extension | OpenRefine | consequence |
|---|---|---|---|
| comma glued to text: `Smith,John` | NACO turns a comma into a space → `john smith` | deletes punctuation with no replacement → `smithjohn` | keys differ whenever a comma abuts characters on both sides; for headings (whose commas separate tokens) the space reading clusters better. Other glued punctuation (`Jean-Paul`) deletes without a space in both tools — only the comma diverges |
| n-gram key of a short string: `marc_ngram_fingerprint('ab', 3)` | a cleaned string shorter than *n* is returned whole → `ab` | yields `""`, colliding *every* short value into one giant cluster | deliberate deviation; documented in `src/include/marc/cluster.hpp` and pinned by `test/cpp/cluster_test.cpp` |
| non-decomposing Latin specials: `Ø Ł ß Æ Œ Þ Đ ı` | folded explicitly (`Łódź` → `lodz`, `straße` → `strasse`, `Ærø` → `aero`) | "normalize extended western characters to their ASCII representation" — a description, not a character table; a fold that only strips combining marks after NFD would leave these unchanged | plain diacritics (`café`/`cafe`) agree everywhere; keys for these specific characters depend on the other side's fold table |
| non-Latin case: `Толстой` vs `толстой` | Greek/Cyrillic pass through uncased — NACO's own documented simplification — so the two forms key apart | lowercases the whole string, so they collide | mixed-case Cyrillic/Greek variants cluster in OpenRefine but not here; CJK is unaffected (no case) |
| the symbols NACO retains: `&` `♭` `♯` | dropped after the NACO pass, honoring "remove all punctuation" — `Trains & Boats & Planes` → `boats planes trains`, `B♭ minor` → `b minor` | `&` is ASCII punctuation and goes there too (agreement); `♭`/`♯` are Unicode *symbols*, so whether OpenRefine's punctuation class removes them is not settled by the published description | treat music-notation strings (`Sonata in F♯`) as potential mismatches |

Everything else matches the description exactly: digits survive (`Route 66`
→ `66 route`), an all-punctuation value keys `''` (and the clustering
macros filter empty keys out), fingerprint tokens re-join with single
spaces, n-grams concatenate with no separator, and word order matters for
n-gram keys but not fingerprint keys (`Cruise, Tom` and `Tom Cruise` share a
fingerprint but not a bigram fingerprint — the grams span the joined
string).

### Worked example: clustering 650 $a

```sql
LOAD marc21;

WITH keyed AS (
    SELECT value AS subject, marc_fingerprint(value) AS key
    FROM read_marc_subfields('bibs.mrc')
    WHERE tag = '650' AND code = 'a')
SELECT key,
       count(*)                                AS n_values,
       count(DISTINCT subject)                 AS n_variants,
       list(DISTINCT subject ORDER BY subject) AS members
FROM keyed
WHERE key <> ''
GROUP BY key
HAVING count(DISTINCT subject) > 1
ORDER BY n_variants DESC, n_values DESC, key;
```

Each row is one cluster worth reviewing: `Cookery, French`,
`French cookery.` and `FRENCH COOKERY` collide on `cookery french`. (Note
that glued punctuation deletes without a space in both tools — a display
form like `United States--History` keys with `stateshistory` as one token,
which is one more reason to cluster the `$a` values themselves rather than
joined heading strings with `--` subdivision separators.) Swap
`marc_fingerprint(value)` for
`marc_ngram_fingerprint(value, 2)` to also catch small internal typos. For
whole 1XX/6XX/7XX headings (all subfields joined, not just `$a`) the table
macro does the same in one call:

```sql
SELECT * FROM marc_cluster_headings('bibs.mrc', 'fingerprint')
WHERE n_variants > 1;
```

The OpenRefine equivalent, on the same column: import the `subjects.tsv`
export from §3, then on the *value* column choose **Edit cells → Cluster and
edit…**, method **Key collision**, keying function **Fingerprint** (or
**N-Gram fingerprint** with *Ngram size* 2). Subject to the divergence table
above, the clusters OpenRefine shows are the rows the SQL returns — so run
the SQL first to decide whether the interactive session is worth opening,
and how big it will be.

## 3. Round trip via TSV

OpenRefine's best import is exactly what `read_marc_subfields` produces:
one row per subfield with stable addressing columns. `record_no` is 1-based
*within each file*, so always carry `file` alongside it as the key.

### Out

```sql
LOAD marc21;

COPY (
    SELECT file, record_no, field_no, subfield_no, value
    FROM read_marc_subfields('bibs.mrc')
    WHERE tag = '650' AND code = 'a'
    ORDER BY file, record_no, field_no, subfield_no
) TO 'subjects.tsv' (FORMAT csv, DELIMITER e'\t', HEADER true);
```

Filter to the column you intend to refine — OpenRefine works best on a
narrow project, and the addressing columns are all you need to get the
refinement back home.

### In OpenRefine

1. Create a project from `subjects.tsv`. **Uncheck "Parse cell text into
   numbers, dates, …"** at import (see the re-typing caveat below).
2. Before editing, preserve the original: on *value*, **Edit column → Add
   column based on this column…**, name it `original`, expression `value`.
3. Refine *value* — cluster-and-merge, facet-and-edit, transforms.
4. **Export → Tab-separated value.** Save as `subjects-refined.tsv`.

### Back

Pin every column type on re-read; never let the sniffer guess:

```sql
CREATE TABLE refined AS
SELECT * FROM read_csv('subjects-refined.tsv',
    delim = e'\t', header = true,
    columns = {
        'file': 'VARCHAR', 'record_no': 'BIGINT',
        'field_no': 'BIGINT', 'subfield_no': 'BIGINT',
        'value': 'VARCHAR', 'original': 'VARCHAR'
    });
```

(For a quick look, `all_varchar = true` and explicit casts work too — the
pattern [RECIPES.md](RECIPES.md) uses for KBART.)

Then apply the refined values to the records, keyed on `(file, record_no)`
and anchored on the original value so only the intended occurrence changes:

```sql
CREATE TABLE bibs AS SELECT * FROM read_marc('bibs.mrc');

UPDATE bibs
SET fields = marc_replace_values(fields, '650', 'a',
                                 '^' || regexp_escape(r.original) || '$',
                                 r.value)
FROM refined r
WHERE bibs.file = r.file AND bibs.record_no = r.record_no
  AND r.value <> r.original
  AND list_contains(marc_subfields(bibs.fields, '650', 'a'), r.original);

COPY (SELECT leader, fields FROM bibs) TO 'bibs-refined.mrc' (FORMAT marc);
```

`marc_replace_values` rewrites every `650 $a` matching the anchored regex —
identical variant strings in one record all get the fix, which is what a
cluster merge means. Two honest notes on this statement:

* **One edit per record per pass.** `UPDATE ... FROM` applies at most one
  matching mapping row to each target row. When a single record has *two
  different* subjects being remapped, one lands per pass — the
  `list_contains` guard makes applied edits stop matching, so simply re-run
  the `UPDATE` until this reports zero:

  ```sql
  SELECT count(*) AS remaining
  FROM bibs, refined r
  WHERE bibs.file = r.file AND bibs.record_no = r.record_no
    AND r.value <> r.original
    AND list_contains(marc_subfields(bibs.fields, '650', 'a'), r.original);
  ```

* **The regex is anchored and escaped.** `regexp_escape` neutralizes the
  metacharacters real headings contain (parenthetical qualifiers,
  `1801-1865` hyphens survive fine, but `Beethoven (Spirit)` would
  otherwise misfire), and `^...$` stops `History` from also rewriting
  `History and criticism`.

For a subfield that occurs at most once per record (a `260 $b`, a `100
$a`), the anchoring is unnecessary and `marc_set_subfield(fields, tagpat,
code, value)` keyed on `(file, record_no)` is the shorter spelling — but
remember it replaces the value of *every* matching subfield in the record
and appends one where missing, so reserve it for non-repeatable situations
(or guard with `len(marc_fields(fields, tagpat)) = 1`).

### The re-typing caveat

OpenRefine and CSV sniffers both like turning strings into numbers and
dates. In MARC data that is corruption: OCLC numbers and ISBNs with leading
zeros (`0316769487` → `316769487`), classification numbers (`082 $a` `004`),
`008`-style date fragments, and `$c` publication dates that come back as
`1999.0` or an ISO timestamp. Defend both ends:

* **into OpenRefine** — uncheck *Parse cell text into numbers, dates, …* at
  project creation; every cell stays a string and exports byte-identical;
* **back into DuckDB** — the `columns = {...}` (or `all_varchar = true`)
  read above; `read_csv` without it will happily type a clean ISBN column
  as `BIGINT`.

`record_no`/`field_no`/`subfield_no` are genuinely numeric and survive
either way; it is the *value* column that must stay `VARCHAR` at every hop.

## 4. Reconciliation

OpenRefine's Reconciliation Service API and the extension's
`marc_reconcile_headings` queue do the same job — match strings to
authority URIs — one candidate list at a time with a human choosing, versus
one queue for the whole corpus with SQL choosing. Use whichever end fits,
and move the results through the same TSV channel as §3.

### Batch: the queue and fetch-then-shape

The extension builds lookup URLs but deliberately does not fetch in a macro
(`read_json` binds its path at plan time — the reasoning is documented atop
`src/macros/reconcile.sql`). The working pattern is fetch-then-shape:

```sql
LOAD marc21;

-- 1. one row per distinct heading: occurrence count + lookup URL
CREATE TABLE queue AS
SELECT * FROM marc_reconcile_headings('bibs.mrc', 'idloc');
-- base: 'idloc' | 'viaf' | 'wikidata', or any literal URL prefix

-- export the URLs for any fetcher
COPY (SELECT url FROM queue) TO 'urls.txt' (FORMAT csv, HEADER false, QUOTE '');
```

Fetch each URL to a file with any HTTP client (one JSON document per
heading), e.g.:

```sh
i=0; while read -r u; do
  curl -s "$u" -o "responses/$((i+=1)).json"; sleep 1
done < urls.txt
```

(With `LOAD httpfs`, `read_json` can also read a *constant* http(s) URL
directly — fine for spot checks, not for a per-row queue.) Then shape and
match:

```sql
-- 2. shape the responses into candidate rows
CREATE TABLE candidates AS
SELECT unnest(marc_idloc_candidates(j), recursive := true)
FROM read_json('responses/*.json', records := false) t(j);
-- marc_viaf_candidates / marc_wikidata_candidates for the other services

-- 3. match candidates back to headings
SELECT q.heading, q.n_occurrences, c.label, c.uri,
       jaro_winkler_similarity(marc_naco(q.heading), marc_naco(c.label)) AS similarity
FROM queue q
JOIN candidates c ON marc_naco(c.label) = marc_naco(q.heading);
```

`marc_naco` equality is the strict criterion;
`jaro_winkler_similarity` (core DuckDB) over the NACO forms grades the
near-misses when you relax the join. Writing accepted matches into `$0`
composes the same way as §3 — here on `100`, which is non-repeatable, so
`marc_set_subfield` keyed on the record is safe:

```sql
CREATE TABLE bibs AS SELECT * FROM read_marc('bibs.mrc');

CREATE TABLE name_matches AS
SELECT s.file, s.record_no, c.uri
FROM read_marc_subfields('bibs.mrc') s
JOIN candidates c ON marc_naco(c.label) = marc_naco(s.value)
WHERE s.tag = '100' AND s.code = 'a'
QUALIFY row_number() OVER (PARTITION BY s.file, s.record_no ORDER BY c.uri) = 1;

UPDATE bibs
SET fields = marc_set_subfield(fields, '100', '0', m.uri)
FROM name_matches m
WHERE bibs.file = m.file AND bibs.record_no = m.record_no;

COPY (SELECT leader, fields FROM bibs) TO 'bibs-linked.mrc' (FORMAT marc);
```

The `QUALIFY` pins one candidate when a heading NACO-matches several. For
repeatable fields (6XX, 7XX) `marc_set_subfield` would stamp the same `$0`
on every occurrence — guard those updates with
`len(marc_fields(bibs.fields, '650')) = 1`, or fall back to per-value
anchoring as in §3.

### Interactive: reconcile in OpenRefine, import the URIs

The other direction plays to OpenRefine's strength — a person vetting each
candidate. Export the heading column as in §3 (`tag = '100' AND code =
'a'`, keeping `file` and `record_no`), then in OpenRefine:

1. On *value*: **Reconcile → Start reconciling…** against the Wikidata
   service OpenRefine ships with, or add a service endpoint for VIAF or
   id.loc.gov from the community service registry.
2. Judge the candidates (facet by judgment to work through the ambiguous
   ones).
3. Extract the accepted URIs into a real column: **Edit column → Add column
   based on this column…**, name `uri`, expression
   `cell.recon.match.id` — for Wikidata prepend the entity prefix:
   `"http://www.wikidata.org/entity/" + cell.recon.match.id`.
4. Export TSV with `file`, `record_no`, `uri`.

Back in DuckDB, the import is one `UPDATE`:

```sql
UPDATE bibs
SET fields = marc_set_subfield(fields, '100', '0', r.uri)
FROM read_csv('reconciled.tsv', delim = e'\t', header = true,
              all_varchar = true) r
WHERE bibs.file = r.file AND bibs.record_no = r.record_no::BIGINT
  AND r.uri <> '';
```

(`all_varchar` keeps unmatched rows' empty `uri` cells as `''` and the key
column honest; the cast restores `record_no`.) The same repeatable-field
guard applies if the column was a 6XX.

A hybrid worth knowing: `marc_reconcile_headings` with a literal URL prefix
as `base` builds a queue against *any* service — including a
Reconciliation-API endpoint's suggest URL — so the corpus-scale unambiguous
matches can be auto-accepted in SQL and only the residue exported for
OpenRefine judgment.

## 5. Which tool for which job

| job | tool |
|---|---|
| applying a refinement to 5M records, repeatably, in a pipeline | marc21 (`marc_replace_values`, `marc_set_subfield`) |
| bulk reconciliation queue + NACO auto-matching, residue to a human | marc21 (`marc_reconcile_headings`, shapers) |
| computing the clusters first, to size or skip that session | marc21 (`marc_cluster_headings`, `marc_fingerprint`) |
| faceting a messy column, judging each cluster merge by eye | OpenRefine |
| joins against other data (KBART, ILS extracts, holdings) | marc21 — plain SQL |
| one-off cell fixes with an undo history | OpenRefine |
| provenance of an interactive session (extract/apply operation JSON) | OpenRefine |
| reading/writing ISO 2709, MARC-8, MARCXML, breaker, Aleph sequential | marc21 — OpenRefine does not parse them |
| reconciliation with human review of every candidate | OpenRefine (Reconciliation Service API) |
| structural record surgery: indicators, field moves, leader, 260→264 | marc21 — OpenRefine has no field model |

The seam between them is always the same file: a TSV with `file`,
`record_no`, and the column being refined.
