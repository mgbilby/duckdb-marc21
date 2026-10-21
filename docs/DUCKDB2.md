# marc21 on DuckDB v2.0

DuckDB v2.0 ("Cyanoptera") is a feature release, and three of its features
change how a catalogue-sized MARC collection behaves: row-group pruning that
skips data instead of scanning it, a multi-file reader framework that every
marc21 reader now sits inside, and a new storage format that makes a large
catalogue cheaper to keep in a `.duckdb` file. This page is what changes for
cataloging work, and — just as importantly — what does not.

**Version applicability.** The released extension is built against **DuckDB
v2.0.0** and that is what `INSTALL marc21 FROM community` gives you. The
capabilities marked **v2.0** below are in the shipped binary; marc21 1.5.6,
built against DuckDB v1.5.6, remains available to clients still on v1.5.6.
The source compiles both ways (`src/include/marc/compat.hpp`), and CI keeps a
v1.5.6 lane on demand. Check what you are on:

```sql
SELECT version();          -- 'v2.0.0' → the v2.0 column below applies
```

| capability | v1.5.6 | v2.0 (shipped) |
|---|---|---|
| glob patterns (`catalogue/*.mrc.gz`) | yes, expanded by the reader | yes, expanded by DuckDB |
| gzip (`.mrc.gz`) | yes | yes |
| parallel scanning within one ISO 2709 file | yes | yes |
| parallel scanning across files | yes | yes |
| `read_marc(['a.mrc', 'b.mrc'])` list argument | no | **yes** |
| `union_by_name`, `hive_partitioning`, `filename`, `allow_empty` | no | **yes** |
| `filename` / `file_index` virtual columns | no | **yes** |
| row-group pruning on landed tables and Parquet | limited | **much wider** |
| `DICT_FSST` string compression by default | no | **yes** |

Row-group pruning and the storage format are properties of *DuckDB*, not of
this extension: they apply once MARC data has been landed into a DuckDB table
or written to Parquet. Nothing prunes a scan of a `.mrc` file — an ISO 2709
dump has no row groups and no statistics. That is the whole reason §1 below is
about landing data rather than about reading it.

## 1. Row-group pruning: making the engine skip what it cannot match

A DuckDB table is stored in **row groups** of 122,880 rows. Every row group
carries a small summary of each column — the minimum and maximum value it
holds (a "zone map"), and for Parquet also an optional Bloom filter of the
exact values present. When the planner can prove from that summary that no row
in a group can satisfy the `WHERE` clause, it never reads the group at all.

v2.0 widens this enormously: zone maps and Bloom filters now prune for
`STRUCT` and `LIST` columns, `DECIMAL`, `UUID`, `IN` lists, and *function
predicates* — `contains(...)`, `substr(...) = ...` and friends, which
previously forced a full scan. For MARC that matters because the columns
catalogers actually filter on are strings: call numbers, control numbers,
subject strings, coded values.

The engine does the skipping. What you control is **layout** — whether the
values that satisfy a query are physically clustered into a few row groups or
smeared evenly across all of them. A min/max summary of a randomly ordered
catalogue is `('A', 'Z')` for every single row group, which prunes nothing.

### 1a. Land the catalogue in sorted order

The one thing worth doing deliberately is choosing a sort key before the
insert. Pick the column your department filters on most; for a bibliographic
file that is usually the LC call number (050 `$a`) or the control number
(001).

```sql
-- Land a catalogue as a queryable table, clustered by LC class.
-- marc_lcc_sortkey is shelflist order, not string order: plain string sorting
-- puts PS10 before PS8, which would scatter a class across the row groups.
-- Keep it as a column too, so range work has a key that sorts correctly.
CREATE TABLE catalogue AS
SELECT control_number,
       marc_subfield(fields, '245', 'a')   AS title,
       marc_subfield(fields, '100', 'a')   AS main_entry,
       marc_subfield(fields, '050', 'a')   AS call_number,
       marc_lcc_sortkey(marc_subfield(fields, '050', 'a')) AS lcc_sort,
       marc_subfields(fields, '650', 'a')  AS subjects,       -- LIST(VARCHAR)
       marc_control_field(fields, '008')   AS f008,
       leader,
       fields                                                  -- the nested record
FROM read_marc('catalogue/*.mrc.gz')
ORDER BY lcc_sort, control_number;
```

`ORDER BY` on a `CREATE TABLE AS` is not cosmetic here: it decides which
records share a row group, and therefore how tight every zone map is. A
catalogue landed this way answers a class question by touching the two or
three row groups that hold that class:

```sql
-- Everything in LC class PS (American literature).  substr() on a column the
-- table is clustered by is exactly the function predicate v2.0 learned to
-- prune on: the engine derives the prefix's range from the column's range.
SELECT control_number, call_number, title
FROM catalogue
WHERE substr(call_number, 1, 2) = 'PS';

-- A narrower band — PS3500–PS3576, American literature 1900- — on the key
-- that sorts correctly:
SELECT control_number, call_number, title
FROM catalogue
WHERE lcc_sort >= marc_lcc_sortkey('PS3500')
  AND lcc_sort <  marc_lcc_sortkey('PS3577');
```

### 1b. What actually prunes, and what does not

Not every function predicate prunes equally well, and it is worth knowing
which is which before you rewrite a query in the hope that it will get faster.

| predicate | prunes when |
|---|---|
| `lcc_sort >= ... AND lcc_sort < ...` | always useful; tightest when the table is sorted by that column |
| `substr(call_number, 1, 3) = 'PS3'` | the engine derives the prefix's min/max from the column's min/max, so this prunes exactly when a plain range on `call_number` would |
| `control_number IN ('ocm00000001', 'ocm00000002', ...)` | a row group is skipped when *every* value in the list is absent from it — on Parquet the Bloom filter decides this without sorting; on a DuckDB table the zone map does, which needs the control numbers clustered |
| `contains(value, 'DO NOT USE')` | only when the row group's summary already settles it: every value in the group is shorter than the search string, or they are short enough and uniform enough that min = max. It is *not* a general substring index |
| `list_contains(subjects, 'Cataloging')` | LIST columns carry child statistics in v2.0, so a group whose subject strings all fall outside the value's range is skipped |

The practical reading: **`contains()` pruning pays on short coded values, not
on long transcribed text.** A 500-note column will not prune on a substring
search no matter how you sort it, because the notes are long and varied and
the row-group summary can never rule the group out. A column of relator codes,
language codes, organization codes or LC class letters will.

So when the job is "find every record with a vendor artifact in a note", do not
expect a substring scan to skip anything — but you can make the *selection*
cheap by landing a narrow coded column beside the text and filtering on that
first:

```sql
-- A subfield-level table for note and heading analysis.  Sorting by tag then
-- code puts all 500 $a values together, all 650 $a values together, and so on:
-- a query restricted to one tag reads only the row groups holding that tag.
CREATE TABLE subfields AS
SELECT control_number, tag, code, value
FROM read_marc_subfields('catalogue/*.mrc.gz')
ORDER BY tag, code, control_number;

-- tag = '500' prunes hard (the zone map on `tag` is exact per row group);
-- the contains() then runs over a few groups instead of the whole file.
SELECT control_number, value
FROM subfields
WHERE tag = '500' AND contains(value, '[electronic resource]');
```

That is the general shape: **put the cheap, selective, well-clustered
predicate first and let it do the pruning; let the expensive text predicate
run over what survives.** It was always good advice; in v2.0 the first half of
it skips I/O instead of merely skipping work.

### 1c. Writing Parquet for a shared catalogue

Parquet is where pruning is most visible, because a Parquet file carries both
zone maps and Bloom filters and DuckDB can skip row groups without opening
their data pages at all. If the department publishes an extract for reuse —
an analytics copy, a discovery-layer feed, a snapshot for the consortium —
write it sorted, and write Bloom filters for the columns people look records
up by:

```sql
COPY (
    SELECT control_number, title, main_entry, call_number, lcc_sort, subjects, f008
    FROM catalogue
    ORDER BY lcc_sort, control_number
) TO 'share/catalogue.parquet' (
    FORMAT parquet,
    ROW_GROUP_SIZE 122880,          -- the default; smaller groups prune finer
    WRITE_BLOOM_FILTER true,        -- exact-value lookups: 001, ISBN, OCLC
    COMPRESSION zstd
);
```

Then a "pull these bibs" request — the single most common batch job in a
cataloging department — reads only the row groups whose Bloom filter admits
one of the control numbers, even though the file is sorted by call number:

```sql
SELECT control_number, title, call_number
FROM 'share/catalogue.parquet'
WHERE control_number IN ('ocm00000001', 'ocm00004312', 'ocm00119877');
```

(A literal `IN` list is what becomes a prunable filter. `IN (SELECT ... FROM
worklist)` is a join, and prunes only through whatever dynamic filter the join
pushes down — for a long worklist, materialize it and pass the values, or
accept the scan.)

Two layout choices earn their keep here:

* **Sort by the thing people filter by, not by the thing people display.**
  A file sorted by title prunes title-range queries and nothing else; a file
  sorted by call number prunes shelflist work, collection-analysis work and
  class-based worklists.
* **Keep the coded columns.** A `f008` column, a `marc_record_type(leader)`
  column, a language column from `marc_control_pos(f008, 35, 3)` — these are
  three to six characters wide, compress to almost nothing, and are exactly
  the columns whose zone maps and Bloom filters are selective.

```sql
-- A profiling extract: every column here is short, coded, and prunes well.
COPY (
    SELECT control_number,
           marc_record_type(leader)              AS rec_type,   -- Leader/06
           marc_bib_level(leader)                AS bib_level,  -- Leader/07
           marc_encoding_scheme(leader)          AS encoding,
           marc_control_pos(f008, 35, 3)         AS language,   -- 008/35-37
           marc_control_pos(f008, 7, 4)          AS date1,      -- 008/07-10
           substr(call_number, 1, 2)             AS lc_class
    FROM catalogue
    ORDER BY lc_class, language
) TO 'share/profile.parquet' (FORMAT parquet, WRITE_BLOOM_FILTER true);
```

### 1d. Partitioning, for collections that grow by batch

v2.0's planner is **partition-aware**: when a dataset is Hive-partitioned, the
optimizer uses the partitioning itself, not just per-file statistics, to decide
what to read. Cataloging data partitions naturally by load — a vendor, a
month, a project:

```sql
COPY (SELECT *, strftime(current_date, '%Y-%m') AS load_month FROM catalogue)
TO 'catalogue_parquet' (FORMAT parquet, PARTITION_BY (load_month));
-- catalogue_parquet/load_month=2026-09/data_0.parquet, ...

SELECT count(*) FROM 'catalogue_parquet/**/*.parquet'
WHERE load_month = '2026-09';     -- opens one directory, not the collection
```

Partition pruning removes whole *files* from the scan before any of them is
opened; row-group pruning then removes groups within the files that remain.
They compose, and for a catalogue that grows by monthly loads they compose
very well.

## 2. Every reader becomes a multi-file reader (v2.0)

On v1.5.6 each reader handles its own file list: it takes one path, expands a
glob if it sees one, and scans the results. On v2.0 each reader is registered
as a **single-file** function wrapped in DuckDB's multi-file framework
(`MarcRegisterReader` in `src/include/marc/compat.hpp`), which then supplies
the file handling on top. All eight file readers go through it:

`read_marc`, `read_marc_subfields`, `read_marc_raw`, `read_marc_breaker`,
`read_marcxml`, `read_marcjson`, `read_alephseq`, `read_microlif`.

(`read_z3950` and the SRU/OAI macros are not file readers and are unaffected.)

### What you get

**A list argument.** Every reader gains an overload taking `LIST(VARCHAR)`
alongside the existing single path, so an explicit file list no longer needs a
`UNION ALL`:

```sql
-- v2.0: one scan over three vendor deliveries
SELECT count(*) FROM read_marc(['vendor/jan.mrc', 'vendor/feb.mrc', 'vendor/mar.mrc']);

-- v1.5.6 equivalent: a glob if the names allow it, else UNION ALL
SELECT count(*) FROM read_marc('vendor/*.mrc');
```

**Multi-file named parameters**, handled by the framework rather than by the
reader, on every reader:

| parameter | meaning for MARC files |
|---|---|
| `filename := true` | add a `filename` column naming the file each row came from — note the readers already emit their own `file` column on both versions, so this is usually redundant |
| `filename := 'source_file'` | the same, under a name of your choosing |
| `union_by_name := true` | combine the files' schemas by column name rather than by position; every marc21 reader has a fixed column list, so this changes nothing for a plain file list — it earns its place over a partitioned tree whose subdirectories do not all carry the same partition keys |
| `hive_partitioning := true` | read `key=value` directory names as columns (`load_month=2026-09/`), and skip whole directories on predicates against them |
| `hive_types := {...}`, `hive_types_autocast := false` | control the types those partition columns get |
| `allow_empty := true` | an empty file list is an empty result instead of an error |
| `maximum_sample_files := n` | how many files are opened to determine the schema; marc21 sets this to 1, because every reader's column list is fixed |

The reader's own named parameters — `encoding`, `tags`, `ignore_errors` —
are forwarded through unchanged, so they combine freely:

```sql
-- v2.0: a hive-partitioned tree of MARCXML, restricted to the fields we want,
-- with the partition column available as an ordinary column to filter on.
SELECT load_month, tag, code, value
FROM read_marcxml('loads/**/*.xml',
                  hive_partitioning := true,
                  tags := '245,650')
WHERE load_month >= '2026-01';
```

**Virtual columns.** `filename` and `file_index` are available on every reader
and cost nothing unless selected.

**Glob and remote paths** are handled by DuckDB rather than by the reader, so
they behave exactly as they do for `read_parquet` and `read_csv` — including
`httpfs` URLs and S3 paths.

### What you do not get — read this before planning around it

Two things that sound like they should follow from the multi-file framework
do not, and it is better to know now than to discover it in a load script:

* **No `file_row_number`.** Parquet supplies that column because its reader
  can produce it; a wrapped table function cannot, and asking for it raises
  "does not support reading virtual columns". Use the reader's own
  `record_no` column instead — it is 1-based within each file, on both
  versions, which is what a cataloger wants anyway ("record 412 of
  `vendor/feb.mrc`").
* **No asynchronous I/O inside a MARC file.** v2.0's async I/O layer is what
  makes Parquet and CSV scans over S3 scale beyond synchronous access, but a
  wrapped table function is always executed synchronously by the framework,
  and marc21 reads its files through the ordinary filesystem interface. What
  *does* scale over object storage is **file-level parallelism**: a glob or
  list of many `.mrc.gz` objects is read by many threads at once. A single
  very large remote file is not read any faster than it is today.

#### `COPY ... FROM` (v2.0)

On v2.0 the four write formats read back too, so a load no longer has to be
spelled as a `SELECT`:

```sql
-- Easiest way to get a table with exactly the reader's column types:
CREATE TABLE incoming AS SELECT * FROM read_marc('vendor/feb.mrc') LIMIT 0;

COPY incoming FROM 'vendor/feb.mrc'   (FORMAT marc);
COPY incoming FROM 'vendor/*.xml'     (FORMAT marcxml);
```

(`fields` is the nested `LIST(STRUCT(tag, ind1, ind2, value, subfields))` —
there is no named `MARC_FIELDS` type to declare, so deriving the table from
the reader with `LIMIT 0` is easier than spelling the struct out.)

`COPY` takes its columns from the target table and the framework maps the
reader's onto them by name, so a table holding only the columns you care about
works as well as the full shape. The glob, `union_by_name` and the partition
options above all apply. On v1.5.x these four formats stay write-only and
loading is `read_marc(...)` plus `INSERT INTO ... SELECT`.

Within one file, the ISO 2709 readers (`read_marc`, `read_marc_subfields`,
`read_marc_raw`) split the file into batches that several threads claim, on
both versions. The text-format readers (`read_marc_breaker`, `read_marcxml`,
`read_marcjson`, `read_alephseq`, `read_microlif`) use one thread per file —
so for those, many medium files parallelize and one huge file does not.
Splitting a 40 GB MARCXML dump into per-load files is worth doing.

## 3. A record as `VARIANT` (v2.0 and v1.5.x)

`marc_variant(leader, fields)` renders a record as DuckDB's `VARIANT`, and
`marc_variant_record(record)` does the same for the `STRUCT(leader, fields)`
that `marc_parse_json` and `marc_new_record` return.

```sql
SELECT marc_variant(leader, fields) AS rec
FROM read_marc('catalogue/*.mrc.gz');

-- what shape is this record?
SELECT variant_typeof(marc_variant(leader, fields))
FROM read_marc('dump.mrc') LIMIT 1;
-- OBJECT(fields, leader)

-- the leader, straight back out
SELECT variant_extract(marc_variant(leader, fields), 'leader')::VARCHAR
FROM read_marc('dump.mrc');
```

The emitted shape is

```json
{ "leader": "00714cam a2200205 a 4500",
  "fields": [ {"tag": "001", "value": "ocm00000001"},
              {"tag": "245", "ind1": "1", "ind2": "0",
               "subfields": [ {"code": "a", "value": "Title /"} ]} ] }
```

Why this is worth having over the ordinary `fields` column: `LIST(STRUCT(tag,
ind1, ind2, value, subfields))` is a single rectangle wide enough for every
kind of field, so every control field carries three `NULL` members it can
never use and every data field a `NULL` `value`. In `VARIANT` a control field
object simply *has no* `ind1`/`ind2`/`subfields` keys — and absent is not the
same as `NULL`, which is exactly the distinction MARC needs: a blank indicator
is `' '`, an indicator that cannot exist is gone. DuckDB then shreds the keys
that really are dense into typed columns and leaves the long tail in the blob,
which is where the storage win comes from.

Field and subfield order is preserved: both levels stay arrays rather than
being keyed by tag or code, because order is semantic in MARC (880 linkage,
repeated 6xx as supplied, and `$a$b$c` is the title statement's word order).

Both functions exist on v1.5.x too — construction is spelled differently
inside the extension, but the SQL surface is identical.

## 4. Reconciliation as a top-k join (v2.0 only)

v2.0 adds `NEAREST` joins, which turn "the *k* most similar rows" into a join
clause instead of a cross join filtered afterwards. `src/macros_v2/nearest.sql`
builds the cataloging cases on top of it:

| macro | question it answers |
|---|---|
| `marc_nearest_recs(path)` | one row per record: `file, record_no, title, tkey, matchkey` — the projection the others start from |
| `marc_nearest_dupes(path, min_similarity := 0.0)` | the 5 most similar *other* records per record, within one corpus |
| `marc_nearest_matches(query_path, target_path, ...)` | the 5 closest target records per query record — "does this vendor load duplicate what we hold?" |
| `marc_nearest_headings(path, labels, ...)` | the 3 closest candidate labels per distinct heading |
| `marc_nearest_key(fields)` | the NACO-normalized `245 $a $b` title key the above rank on |

```sql
-- Does the February shipment duplicate the catalogue?
SELECT * FROM marc_nearest_matches('vendor/feb.mrc', 'catalogue/*.mrc.gz',
                                   min_similarity := 0.92);
```

Two deliberate choices. These use `EXACT`, not `APPROX`: there is no
approximate index for Jaro-Winkler, and a duplicate report that silently drops
pairs is worse than a slow one. And a record with no `245 $a` ranks `NULL`,
which the join drops — so an untitled record is simply not a candidate rather
than matching everything.

`k` has to be a positive integer *literal* in DuckDB's grammar, so it cannot
be a macro parameter. When you need a different `k`, `marc_nearest_matches_k(
query_path, target_path, k)` builds the statement and runs it through
`query()`.

## 5. Where the functions live (both versions), and what a scan reports (v2.0)

**The same flat namespace as before.** On v2.0, as on v1.5.x, marc21
registers its readers, scalars and macros where every extension's functions
have always gone, so `read_marc(...)` and `marc_subfield(...)` resolve
unqualified exactly as before. There is no `marc21` schema to qualify with.

v2.0 does let an extension register into a schema of its own, and marc21
tried it (`MarcUseExtensionSchema` in `src/include/marc/compat.hpp`). In the
CLI, unqualified calls still resolved, because DuckDB appends extension
schemas to the search path. In the sqllogictest harness the community CI runs,
they did not: 41 of 42 test files failed with "Table Function with name
read_marc_breaker does not exist! Did you mean
system.marc21.read_marc_breaker?". Whether a call resolves would then depend
on how the embedding application set up its connection, which an extension
cannot control. For a library whose users have years of `read_marc(...)` in
their scripts, that would be a breaking change, so the namespace stays flat.

**What a scan counted.** The ISO 2709 readers report through the profiler:

```sql
PRAGMA enable_profiling = 'query_tree';
SELECT count(*) FROM read_marc('catalogue/*.mrc.gz');
```

alongside the usual operator metrics you get `marc_records_parsed`,
`marc8_records`, `marc_utf8_records` and `marc_decode_errors` (all listed in
`duckdb_available_metrics`). "How much of this dump is still MARC-8?" and "how
many records failed to decode?" are the first two questions anyone asks of an
unfamiliar file, and this answers both from the scan you were running anyway
rather than a second pass. Encoding is classified from leader/09.

## 6. A large catalogue kept in DuckDB (v2.0)

If the department's working copy of the catalogue lives in a `.duckdb` file
rather than being re-read from `.mrc` every time, the v2.0 storage format is
the change you will feel:

* **`DICT_FSST` string compression is on by default.** MARC data is
  overwhelmingly short, repetitive strings — tags, indicators, subfield codes,
  relator terms, place names, publisher names, the same 650 `$a` heading
  across thousands of records. Dictionary compression with FSST on top of it
  is close to the ideal case for this data, and it applies without you
  choosing anything.
* **Column metadata is loaded lazily.** A landed MARC table is wide by nature
  — a `fields` column of nested structs, plus every extracted column a report
  ever needed. Lazily loading the per-column metadata means the database opens
  fast and the columns a query does not touch cost no memory.
* **Deletes are stored compactly.** Weeding runs, suppressed-record purges and
  "delete the failed load and try again" cycles leave delete markers behind;
  v2.0 stores them far more cheaply, which matters for a table that is
  repeatedly loaded and pruned.
* **Checkpoint vacuuming can compact tables with ART indexes** by remapping
  index entries incrementally instead of rebuilding the index — so a
  `UNIQUE`/primary-key index on `control_number` no longer makes compaction
  expensive.

The catch is compatibility, and it is worth stating plainly: **v2.0 writes
storage format v2.0.0 by default, and a v1.5.6 binary cannot open it.** If the
same database file has to be readable by an older DuckDB — a colleague's
install, a pinned analytics box — create or attach it with an explicit
version:

```sql
ATTACH 'catalogue.duckdb' AS cat (STORAGE_VERSION 'v1.5.0');
```

Parquet is unaffected by any of this; a Parquet extract written by v2.0 is
read by older DuckDBs and by everything else that reads Parquet. For an
interchange copy of a catalogue, that remains the safer format.

## 7. What does not change

Worth saying, because a major version bump invites the question:

* **Every function in [REFERENCE.md](REFERENCE.md) keeps its name, arity and
  meaning.** The v2.0 work is a port of the extension's internals to moved API
  surfaces (`src/include/marc/compat.hpp` holds the shims), not a redesign of
  the SQL surface.
* **The record model is the same.** `leader` plus the nested
  `LIST(STRUCT(tag, ind1, ind2, value, subfields))`, NFC-normalized values,
  per-record MARC-8 detection, `record_no` 1-based per file.
* **Every writer is the same.** `COPY ... TO 'f' (FORMAT marc | marcxml | mrk
  | marcjson)` with `ENCODING` and `NORMALIZE`, round-tripping against the
  readers.
* **No new dependencies.** The extension stays dependency-free and loads in
  WASM, on both versions.

Everything in §1 that concerns layout — sorting before landing, keeping coded
columns, partitioning by load — is worth doing on v1.5.6 today. It costs
nothing, it already helps, and it is what makes v2.0's pruning pay off the day
you upgrade.

Worked cataloging jobs built on these layouts: [RECIPES.md](RECIPES.md) §9.
