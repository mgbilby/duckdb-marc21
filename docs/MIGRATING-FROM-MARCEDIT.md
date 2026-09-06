# Migrating from MarcEdit

A tool-by-tool map from MarcEdit's utilities to marc21 SQL. Every "Available"
row carries SQL that was executed against this repository's `test/data`
fixtures before being written down — run the examples verbatim from the repo
root. The Roadmap summary at the end lists what still has no marc21
equivalent, and says so honestly.

This guide describes MarcEdit's *documented behavior* for orientation only;
marc21 is an independent, clean-room implementation (see CONTRIBUTING.md) and
shares no code or lineage with MarcEdit.

## The mental shift

MarcEdit edits a file in place: open in MarcEditor, run a global edit, save.
marc21 is SQL over immutable inputs: **readers** turn MARC files into rows,
**scalar functions** transform a record's `fields` value and return a new
one, and **`COPY`** writes the result to a new file. An entire MarcEdit
session becomes one statement:

```sql
COPY (
    SELECT leader,
           marc_set_subfield(marc_remove_fields(fields, '9..'),
                             '040', 'e', 'rda') AS fields
    FROM read_marc('in.mrc')
) TO 'out.mrc' (FORMAT marc);
```

Two shapes matter everywhere below:

* `read_marc(path)` — one row per record: `leader` plus the nested
  `fields` list (`LIST(STRUCT(tag, ind1, ind2, value, subfields))`);
* `read_marc_subfields(path)` — one row per subfield, for reporting.

## Tool map at a glance

| MarcEdit tool | marc21 equivalent | status |
|---|---|---|
| Add Field | `marc_add_field`, `marc_add_local` | Available |
| Build New Records | `marc_new_record` | Available |
| Character conversion (MARC-8 ↔ UTF-8) | `COPY ... (FORMAT marc, ENCODING ...)` | Available |
| Copy Field | `marc_copy_field` | Available |
| Delete Field | `marc_remove_fields`, `marc_remove_subfield` | Available |
| Delimited Text Translator (text → MARC) | `marc_from_delimited` + preset mappings | Available |
| Edit Indicator Data | `marc_set_indicators` | Available |
| Edit Subfield / Replace | `marc_set_subfield`, `marc_replace_values` | Available |
| Export Tab Delimited Records | `SELECT` + `COPY (FORMAT csv)` | Available |
| Extract / Delete Selected Records | `WHERE` predicate on any function | Available |
| Field Count report | `marc_report_tags`, `marc_report_subfields` | Available |
| Find Duplicate Records | `marc_dedupe_key`, `marc_dedupe_candidates` | Available |
| MARC SQL Explorer | the whole extension | The whole extension is this feature |
| MARC ↔ JSON | `read_marcjson` / `COPY (FORMAT marcjson)` | Available |
| MARC ↔ MARCXML | `read_marcxml` / `COPY (FORMAT marcxml)` | Available |
| MarcBreaker (MARC → mnemonic .mrk) | `COPY ... (FORMAT mrk)` | Available |
| MARCCompare | `marc_diff` | Available |
| MARCJoin | glob patterns in `read_marc` | Available |
| MarcMaker (.mrk → MARC) | `marc_readnestedbreaker` + `COPY (FORMAT marc)` | Available |
| MARCSplit | `COPY` with `WHERE` | Available |
| MARCValidator | `marc_validate_format`, `marc_report_errors` | Available |
| Merge Records | `marc_merge` | Available |
| OAI harvester | `marc_readoai` | Available (network) |
| RDA Helper | `marc_rda_check` / `marc_generate_33x` / `marc_rda_expand` | Available |
| Replace All from an external list | `marc_replace_all` + `read_csv` | Available |
| Sort fields (MARCSort) | `marc_sort_fields` | Available |
| SRU client | `marc_readsru` | Available (network) |
| Swap Field Data | `marc_swap_fields`, `marc_move_field`, `marc_rename_subfield` | Available (see below for the remaining edge) |
| Tasks / Task Manager | task bundles (macro `.sql` files) | Convention (docs/TASKS.md) |
| Z39.50 client | `read_z3950` | Available (network) |

## Format conversion

### MarcBreaker / MarcMaker

MarcEdit round-trips binary MARC through the mnemonic `.mrk` text format so
records can be edited as text. marc21 reads and writes `.mrk` directly:

```sql
-- MarcBreaker: binary -> mnemonic
COPY (SELECT leader, fields FROM read_marc('test/data/sample_utf8.mrc'))
TO 'out.mrk' (FORMAT mrk);

-- MarcMaker: mnemonic -> binary
COPY (SELECT * FROM marc_readnestedbreaker('test/data/sample.mrk'))
TO 'out.mrc' (FORMAT marc);
```

`read_marc_breaker(path)` gives the same `.mrk` file as one row per subfield
when you only want to query it, not convert it. And because edits here are
SQL functions rather than text manipulation, most reasons to break to text
disappear — you can stay in binary MARC end to end.

### MARCJoin

MarcEdit's MARCJoin concatenates record files. marc21 readers take glob
patterns (and gzip), so joining is reading many files and writing one:

```sql
COPY (SELECT leader, fields FROM read_marc('test/data/sample_*.mrc'))
TO 'joined.mrc' (FORMAT marc);
-- 5 records from 3 files in test/data
```

The `file` column preserves provenance while the records are still apart —
`SELECT file, count(*) FROM read_marc('batch/*.mrc') GROUP BY file`.

### MARCSplit

MarcEdit splits a file into N-record chunks. marc21 splits on *meaning* —
any predicate — one `COPY` per output file:

```sql
COPY (SELECT leader, fields FROM read_marc('test/data/sample_utf8.mrc')
      WHERE marc_subfield(fields, '245', 'a') LIKE 'The %')
TO 'the_titles.mrc' (FORMAT marc);
```

Count-based chunks use `record_no` the same way
(`WHERE record_no BETWEEN 1 AND 1000`, then `1001 AND 2000`, ...).

### MARCXML and JSON

```sql
COPY (SELECT leader, fields FROM read_marc('test/data/sample_utf8.mrc'))
TO 'out.xml' (FORMAT marcxml);
COPY (SELECT leader, fields FROM read_marc('test/data/sample_utf8.mrc'))
TO 'out.json' (FORMAT marcjson);

SELECT count(DISTINCT record_no) FROM read_marcxml('out.xml');   -- 3
SELECT count(DISTINCT record_no) FROM read_marcjson('out.json'); -- 3
```

`read_marcxml` also unwraps SRU/OAI envelopes; `read_marcjson` handles
MARC-in-JSON objects, arrays, NDJSON and FOLIO SRS envelopes. Aleph
sequential comes in through `read_alephseq`.

### Character conversion (MARC-8 ↔ UTF-8)

MarcEdit's character-set conversions map to the `ENCODING` option of the
binary writer and the readers' `encoding` parameter (autodetected by
default, Leader/09):

```sql
-- UTF-8 -> MARC-8, full LC sets with escape designations
COPY (SELECT leader, fields FROM read_marc('test/data/sample_utf8.mrc'))
TO 'as_marc8.mrc' (FORMAT marc, ENCODING 'marc8');

-- and back: 'Łódź and the river :' survives the round trip
SELECT marc_subfield(fields, '245', 'a')
FROM read_marc('as_marc8.mrc', encoding := 'marc8') WHERE record_no = 1;
```

The MARC-8 tables cover ANSEL, Cyrillic, Greek, Hebrew, Arabic and EACC
(see `test/data/edge/multiscript_marc8.mrc` for a mixed-script exhibit);
characters in no LC set are written as `&#xHHHH;` NCRs.

## Global edits (MarcEditor batch changes)

All editing functions take a `fields` value and return a new one, so they
nest — one composed expression replaces a MarcEdit task's list of steps.
Tag patterns accept `.` wildcards (`'9..'` = all 9XX).

### Add Field

```sql
SELECT marc_add_field(fields,
         {'tag': '500', 'ind1': ' ', 'ind2': ' ', 'value': NULL,
          'subfields': [{'code': 'a', 'value': 'Added by batch edit.'}]})
FROM read_marc('test/data/sample_utf8.mrc');
```

For local fields built from plain values, `marc_add_local(fields, tag, i1,
i2, codes, values)` takes parallel lists and inserts in tag order, and
`marc_stamp(fields, org)` adds the conventional `949 $a org $d <date>` load
stamp.

### Delete Field

```sql
-- drop every 650 (wildcards work: '6..' drops all 6XX)
SELECT marc_remove_fields(fields, '650') FROM read_marc('test/data/sample_utf8.mrc');
-- drop one subfield everywhere: the deprecated 245 $h GMD
SELECT marc_remove_subfield(fields, '245', 'h') FROM read_marc('test/data/sample_utf8.mrc');
```

### Edit Subfield / Find-and-Replace

`marc_set_subfield` sets (or appends) a subfield's value outright;
`marc_replace_values` is the regex find-and-replace, scoped to a tag pattern
and optionally one subfield code (`NULL` = all codes):

```sql
SELECT marc_set_subfield(fields, '040', 'e', 'rda') FROM read_marc('in.mrc');

-- replace exactly 'Poland' in 650 $z; 'Poland.' with the period is untouched
SELECT marc_subfields(
         marc_replace_values(fields, '650', 'z', '^Poland$', 'Polska'),
         '650', 'z')
FROM read_marc('test/data/sample_utf8.mrc') WHERE record_no = 1;
-- [Polska, Łódź., Poland.]
```

MarcEdit's *Replace All ... using an external list* (a delimited file of
find/replace rules, run in one pass) is `marc_replace_all(fields, rules)` —
the rules list applies in order, so later rules see earlier rules' output,
and each entry is `{tag, code, find, replace}` (`code: NULL` = every code).
Aggregate the rules file into the list argument:

```sql
SELECT marc_replace_all(fields,
         (SELECT list(struct_pack(tag := tag, code := code,
                                  find := find, replace := replace))
          FROM read_csv('rules.csv', all_varchar := true)))
FROM read_marc('test/data/sample_utf8.mrc');
```

### Edit Indicator Data

```sql
SELECT marc_set_indicators(fields, '245', '0', '0') FROM read_marc('in.mrc');
```

### Swap Field Data / Copy Field

Whole-field moves and copies are dedicated functions, all keeping order,
indicators and subfields exactly as they were:

```sql
-- MarcEdit "440 -> 490": renumber every 440 in place
SELECT marc_move_field(fields, '440', '490') FROM read_marc('in.mrc');

-- Copy Field: every 245 also becomes a 246, original untouched
SELECT marc_copy_field(fields, '245', '246') FROM read_marc('in.mrc');

-- true swap: every 440 becomes 490 AND every 490 becomes 440, in place
SELECT marc_swap_fields(fields, '440', '490') FROM read_marc('in.mrc');
```

`marc_move_field`/`marc_copy_field` take `.` wildcards in the source
(`'9..'` retags all 9XX); `marc_swap_fields` takes two literal tags. All
three refuse to cross the control/data boundary (a 245 cannot become an
007 — the field has no structure to put there). The subfield half of
MarcEdit's Swap Field Data — move $x data to $z within a field — is
`marc_rename_subfield`:

```sql
-- every 650 $z becomes 650 $x, values and subfield order kept
SELECT marc_subfields(marc_rename_subfield(fields, '650', 'z', 'x'), '650', 'x')
FROM read_marc('test/data/sample_utf8.mrc') WHERE record_no = 1;
-- [Poland, Łódź., Poland.]
```

The remaining edge: moving subfield data *across* fields (245 $h into a new
655) or reordering codes within one field has no single function — compose
`marc_build_field` (which can pull any `{tag$code}` into a new field) with
`marc_remove_subfield` for the cross-field case.

### Sorting fields

`marc_sort_fields(fields)` is the MARCSort operation: a stable tag sort, so
repeated tags keep their occurrence order and nothing inside a field
changes. Verified against `test/data/edge/odd_fields.mrc`, whose fields are
deliberately out of order:

```sql
SELECT list_transform(marc_sort_fields(fields), lambda f: f.tag)
FROM read_marc('test/data/edge/odd_fields.mrc');
-- [001, 100, 245, 500, 650]   (stored order is 001, 500, 245, 100, 650)
```

Note the writers deliberately preserve whatever order you give them, so
sort (or don't) explicitly before `COPY`.

## RDA Helper

MarcEdit's RDA Helper adds 33X fields, expands AACR2 abbreviations, handles
the GMD and marks the record RDA. marc21 splits this into a checker and
per-concern fixers so you control exactly what changes:

```sql
-- what would the RDA Helper want to touch?
SELECT marc_rda_check(leader, fields)
FROM read_marc('test/data/sample_utf8.mrc') WHERE record_no = 1;
-- [desc_aacr2, no_040e_rda, missing_336, missing_337, missing_338]

-- the mechanical fixes, composed (see docs/RECIPES.md section 7)
COPY (
  SELECT substr(leader, 1, 18) || 'i' || substr(leader, 20) AS leader,
         marc_set_subfield(
           marc_rda_expand(
             marc_generate_33x(leader,
               marc_remove_subfield(fields, '245', 'h'))),
           '040', 'e', 'rda') AS fields
  FROM read_marc('test/data/sample_utf8.mrc')
) TO 'bibs_rda.mrc' (FORMAT marc);
```

`marc_generate_33x` derives 336/337/338 from the leader (`text`/`txt`/
`rdacontent` and friends); `marc_rda_expand` spells out `p.`, `ill.`, `ed.`
etc. in transcription fields. `examples/tasks/rda-upgrade.sql` packages the
whole flow as a reusable task bundle.

## Validation and reports

### MARCValidator

```sql
-- rulepack validation, dispatched on Leader/06 (bib/authority/holdings)
SELECT record_no, unnest(marc_validate_format(leader, fields)) AS violation
FROM read_marc('test/data/sample_utf8.mrc');
-- records 2 and 3: '008: required field missing'
```

`marc_validate` is the structural layer, `marc_validate_bib` / `_auth` /
`_holdings` pin a rulepack, `marc_validate_avram` takes your own Avram
schema, and `marc_report_errors(path)` is the whole file's structural report
as a table.

### Field Count

```sql
SELECT * FROM marc_report_tags('test/data/sample_utf8.mrc');
-- tag | count | records_with | pct_records
SELECT * FROM marc_report_subfields('test/data/sample_utf8.mrc', '650');
-- code | count | records_with
```

`marc_summary`, `marc_summary_fields`, `marc_summary_subfields` and
`marc_report_completeness` go further than MarcEdit's counts (distributions,
coverage, weighted completeness scores).

### Find Duplicate Records

```sql
-- exact pass: normalized title|ISBN|year key
SELECT marc_dedupe_key(fields) AS k, count(*), list(control_number)
FROM read_marc('test/data/sample_utf8.mrc')
GROUP BY k HAVING count(*) > 1;

-- fuzzy pass: pairwise Jaro-Winkler over NACO-normalized titles
SELECT * FROM marc_dedupe_candidates('test/data/sample_utf8.mrc', 0.93);
```

`examples/tasks/dedupe-report.sql` adds a keeper suggestion per duplicate
group using `marc_rank` (encoding level + completeness) — something
MarcEdit's dedupe leaves to eyeballing.

### MARCCompare

```sql
SELECT unnest(marc_diff(a.leader, a.fields, b.leader, b.fields))
FROM read_marc('old.mrc') a
JOIN read_marc('new.mrc') b USING (record_no);
-- {'kind': changed, 'tag': 245, ..., 'a': '=245  14$aThe empty record.',
--                                    'b': '=245  14$aChanged'}
```

One row per added/removed/changed field, rendered in breaker syntax on both
sides. Join on `control_number` instead of `record_no` when files are not
positionally aligned.

## Selecting, extracting, merging

MarcEdit's Extract/Delete Selected Records dialogs become `WHERE`:

```sql
-- extract
COPY (SELECT leader, fields FROM read_marc('test/data/sample_utf8.mrc')
      WHERE list_contains(marc_subfields(fields, '650', 'a'), 'Rivers'))
TO 'selected.mrc' (FORMAT marc);
-- delete selected = the same COPY with the predicate negated
```

Any function works in the predicate — `marc_spec(leader, fields, '008/35-37')`,
`marc_validate_format(...)`, a join against a list of control numbers.

`marc_merge(base, incoming, protected_csv, replace_csv, add_csv, default)`
merges two records field-group-wise (keep/replace/add per tag list) for
overlay workflows; `marc_rank` picks which record should be the base.

## Networked retrieval (Z39.50 / SRU / OAI)

These require network access (`enable_external_access`; SRU/OAI also
`LOAD httpfs`), so unlike everything above they were not exercised against
local fixtures — signatures verified, semantics documented in
docs/REFERENCE.md:

```sql
SELECT hits, marc_subfield(fields, '245', 'a')
FROM read_z3950('z3950.loc.gov', 7090, 'VOYAGER', '@attr 1=7 0316769487');

SELECT * FROM marc_readsru('https://lx2.loc.gov:210/lcdb',
                           'dc.title = "moby dick"', 5);

SELECT * FROM marc_readoai('https://example.org/oai', 'marc21', NULL);
```

`read_z3950` is a built-in dependency-free Z39.50-1995 client (Init → Search
→ Present, Bib-1 attributes); MarcEdit's Z39.50 batch-search-from-file
becomes a lateral join of your search-term table against it.

## Delimited Text Translator

The one-call translator is `marc_from_delimited(material, mapping)`: one
record per spreadsheet row, built from a mapping list of
`{tag, i1, i2, code, value}` entries over the `marc_new_record(material)`
skeleton (entries sharing tag+indicators merge into one field; blank cells
drop their subfield; see docs/REFERENCE.md). For the common layouts, named
**presets** supply the mapping — just hand them your columns:

```sql
-- CSV columns title,author,isbn,publisher,pubyear -> book records
COPY (
  SELECT r.leader AS leader, r.fields AS fields
  FROM (SELECT marc_from_delimited('book',
                 marc_delimited_preset_books(title, author, isbn,
                                             publisher, pubyear)) AS r
        FROM read_csv('titles.csv', all_varchar = true))
) TO 'from_csv.mrc' (FORMAT marc);
```

`marc_delimited_preset_serials(title, issn, publisher)` and
`marc_delimited_preset_eresources(title, url, isbn)` cover the other two
stock layouts, and a preset is just a mapping list — append your own
entries with `||`, or write the whole mapping by hand for anything the
presets don't say. (There is deliberately no `marc_delimited_preset(name,
...)` dispatcher: SQL macros have fixed argument lists, so one macro cannot
take five columns for books but three for serials.) `all_varchar` keeps
ISBNs from sniffing as integers. The reverse —
MarcEdit's Export Tab Delimited Records — is just a projection:

```sql
COPY (SELECT control_number,
             marc_subfield(fields, '245', 'a') AS title,
             marc_subfield(fields, '100', 'a') AS author
      FROM read_marc('test/data/sample_utf8.mrc'))
TO 'export.tsv' (DELIMITER '\t', HEADER);
```

## Tasks

MarcEdit Tasks record a sequence of edits for replay. The marc21 equivalent
is a **task bundle**: a `.sql` file of `CREATE OR REPLACE MACRO` statements
with a documented header, loaded with `.read` (or `-init`) and applied with
one `COPY`. The convention and three tested bundles
(`vendor-load-cleanup`, `rda-upgrade`, `dedupe-report`) live in
[TASKS.md](TASKS.md) and `examples/tasks/`.

## Roadmap summary

Closed since earlier revisions of this guide: whole-field moves, copies and
swaps (`marc_move_field` / `marc_copy_field` / `marc_swap_fields`),
subfield renames (`marc_rename_subfield`), field sorting
(`marc_sort_fields`), rules-table find-and-replace (`marc_replace_all`),
and the mapping-driven translator (`marc_from_delimited` + presets). What
remains, honestly stated:

| gap | notes |
|---|---|
| Cross-field subfield moves / subfield reordering | no single function; compose `marc_build_field` + `marc_remove_subfield` for the cross-field case |
| Linked-data / $0 enrichment (MarcEdit's linked-data tools) | `marc_uris` / `marc_ids_lc` extract identifiers and the reconcile macros build lookup URLs, but nothing fetches results or writes $0s back — a full fetch-and-writeback loop is out of scope for the offline extension |
| Task *recorder* | bundles are written as SQL (convention + tested examples in docs/TASKS.md); nothing records a UI session into a bundle |
