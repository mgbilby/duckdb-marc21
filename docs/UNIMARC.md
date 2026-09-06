# UNIMARC — what works today, and what does not

UNIMARC records are ISO 2709 records, and `read_marc()` is an ISO 2709
reader.  That sentence is the whole feature: the *structure* of a UNIMARC
file — leaders, directories, tags, indicators, subfields — parses exactly
like MARC 21.  Everything layered on top of the structure (field semantics,
encoding detection, validation rulepacks, crosswalks) is MARC 21-specific
and either needs care or does not apply.  This page is the honest map.

The worked examples use `test/data/unimarc.mrc`, a hand-built
single-record UTF-8 UNIMARC file committed for exactly this purpose
(exercised by `test/sql/marc_unimarc.test`).

## What works

### Structural reading — fully

```sql
SELECT record_no, len(fields), leader
FROM read_marc('test/data/unimarc.mrc', encoding := 'utf8');
-- 1 | 6 | 00256nam0 2200097   450␣
```

The UNIMARC leader comes through verbatim, including the parts that differ
from MARC 21 (position 9 undefined, entry map `450␣` at 20-23).  The reader
takes the base address from the directory terminator rather than trusting
leader/12-16, which makes it robust to the length lies common in vendor
UNIMARC just as in vendor MARC 21.

### UTF-8 UNIMARC — reads fine, with one explicit parameter

```sql
SELECT marc_subfield(fields, '200', 'a') AS title,
       marc_subfield(fields, '200', 'f') AS responsibility
FROM read_marc('test/data/unimarc.mrc', encoding := 'utf8');
-- Les canards du Québec | Amélie Côté
```

The parameter is not optional.  MARC 21 declares UTF-8 in leader/09 = `a`;
UNIMARC leaves leader/09 undefined (blank) and declares its character sets
in field 100 $a positions 26-29 (`50` = ISO 10646).  `read_marc`'s
auto-detection only knows the MARC 21 convention, so a UTF-8 UNIMARC record
auto-detects as MARC-8 and non-ASCII is mangled:

```sql
SELECT marc_subfield(fields, '200', 'a')
FROM read_marc('test/data/unimarc.mrc');       -- encoding := 'auto'
-- Les canards du Qu©♭bec        (é read as two MARC-8 bytes: ©, ♭)
```

Nothing errors — the bytes are simply decoded by the wrong table.  **Always
pass `encoding := 'utf8'` for UTF-8 UNIMARC.**

The declaration itself is queryable, so a corpus can be checked before
trusting it:

```sql
SELECT substr(marc_subfield(fields, '100', 'a'), 27, 2) AS charset  -- '50' = Unicode
FROM read_marc('unimarc.mrc', encoding := 'utf8');
```

### Structural navigation, reports, editing — work, tags mean UNIMARC things

`marc_fields`, `marc_subfield(s)`, `marc_control_field`, `marc_spec`, the
`marc_report_*`/`marc_summary*` table macros, the editing surface
(`marc_add_field`, `marc_set_subfield`, ...) and `COPY (FORMAT marc |
marcxml | mrk | marcjson)` all operate on tags, codes and values without
caring which MARC dialect assigned their meaning.  A tag-frequency report of
a UNIMARC file is a perfectly good tag-frequency report.

You must bring the UNIMARC semantics yourself: the title is `200$a` (not
245), the language field is `101` (not 008/35-37), personal authors are
`700`/`701`/`702` (main/alternative/secondary responsibility, not
added-entry), publication is `210` (or `214` in recent UNIMARC).

## What does not work (and is not pretended to)

* **ISO 5426 legacy encoding is NOT converted.**  Pre-Unicode UNIMARC is
  normally ISO 5426 ("extended Latin"), whose diacritic bytes differ from
  MARC-8/ANSEL.  There is no ISO 5426 decoder here: `encoding := 'utf8'`
  will U+FFFD-replace the invalid sequences, and `encoding := 'marc8'`
  (or auto) will decode them by the wrong table.  ASCII-only legacy records
  read fine either way; accented ones need external conversion (e.g.
  `yaz-iconv -f ISO5426 -t UTF8`) before ingest.
* **MARC 21 semantic helpers give MARC 21 answers.**  `marc_dublin_core`,
  `marc_instance`, `marc_mods_xml`, `marc_headings`, `marc_matchkey`,
  `marc_008_struct`, `marc_encoding_scheme` and friends read MARC 21 tags
  and positions; on UNIMARC input they run without error but look in the
  wrong places (a UNIMARC record has no 245, its 100 is processing data,
  its 700 is a main author).  Do not use their output for UNIMARC.
* **Validation rulepacks are MARC 21 rulepacks.**  `marc_validate_bib` /
  `_auth` / `_holdings` and `marc_validate`'s tag-level conventions know
  nothing of UNIMARC's tag blocks; expect noise like `no 245 (title) field`
  on perfectly valid UNIMARC.  `marc_validate_avram(leader, fields, schema)`
  *does* work with a UNIMARC Avram schema supplied by the caller.
* **Writing produces MARC 21-flavored leaders.**  `COPY (FORMAT marc)`
  recomputes leader/00-04 and 12-16 (correct for any ISO 2709) but also
  stamps leader/09 = `a`, which is a MARC 21 convention; a UNIMARC consumer
  that checks 100 $a/26-29 instead will not care, but byte-identical
  round-tripping of the leader is not guaranteed at position 9.

## Building the fixture

`test/data/unimarc.mrc` was constructed field-by-field (001, 100,
101, 200, 210, 700 with proper UNIMARC indicator conventions and a 100 $a
declaring character set `50`) and serialised as standard ISO 2709 with the
directory and record lengths computed from the actual byte lengths — no
UNIMARC-specific machinery was needed, which is rather the point.
