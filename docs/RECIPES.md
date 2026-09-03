# marc21 — cataloging workflow recipes

Worked SQL for common cataloging-department jobs. The macros stay small and
per-record; everything cross-record (joining a bib file against an authority
file, diffing two authority snapshots, auditing links) is ordinary SQL shown
here. `fields` always means the nested `LIST(STRUCT(tag, ind1, ind2, value,
subfields))` value produced by `read_marc()`.

## 1. KBART holdings → minimal MARC e-resource records

KBART files (NISO RP-9) are tab-separated with one header row and purely
textual values. `marc_read_kbart(path)` reads one with
`delim=e'\t', header=true, all_varchar=true, normalize_names=false` and
passes the file's columns through unchanged (`SELECT *`) — vendor files omit
and append columns freely, so the macro does not demand the standard column
list; check for what you need with `COLUMNS(...)` or a plain projection.

```sql
-- Inspect a vendor file
SELECT publication_title, online_identifier, title_url
FROM marc_read_kbart('vendor/ebooks.tsv');

-- Build minimal records and write ISO 2709 for your ILS loader.
-- marc_kbart_to_marc returns STRUCT(leader, fields):
--   leader '00000nam a2200000 a 4500' (fixed, monograph-style even for
--   serials; the writer recomputes lengths), 022 $a when online_identifier
--   normalizes as an ISSN, else 020 $a when it normalizes as an ISBN
--   (ISBN-10s become ISBN-13s), 245 00 $a, 260 $b, 856 40 $u.
COPY (
    SELECT r.leader AS leader,
           marc_stamp(r.fields, 'XX-MyOrg') AS fields   -- provenance (recipe 2)
    FROM (SELECT marc_kbart_to_marc(publication_title, online_identifier,
                                    title_url, publisher_name) AS r
          FROM marc_read_kbart('vendor/ebooks.tsv'))
) TO 'load/ebooks.mrc' (FORMAT marc);
```

To add a link to existing records instead of building new ones,
`marc_kbart_856(title_url, link_text)` returns an 856 40 `$u` (`$z` when
`link_text` is not NULL) field struct for `marc_add_field`:

```sql
SELECT marc_add_field(b.fields, marc_kbart_856(k.title_url, 'Available online'))
FROM read_marc('bibs.mrc') b
JOIN marc_read_kbart('vendor/ebooks.tsv') k
  ON marc_isbn13(marc_subfield(b.fields, '020', 'a')) = marc_isbn13(k.online_identifier);
```

## 2. Local-field templating and load stamping

`marc_add_local(fields, tag, i1, i2, codes, values)` builds a data field from
parallel code/value lists and inserts it in tag order:

```sql
SELECT marc_add_local(fields, '590', ' ', ' ',
                      ['a', '5'], ['Bound with v.2', 'XX-MyOrg'])
FROM read_marc('in.mrc');
```

`marc_stamp(fields, org_code)` is the one-line provenance template:
`949 __ $a org_code $d <load date>` (`current_date` as YYYY-MM-DD). 949/$d
are conventional local choices — reach for `marc_add_local` directly when
site practice differs:

```sql
COPY (SELECT leader, marc_stamp(fields, 'XX-MyOrg') AS fields
      FROM read_marc('vendor.mrc'))
TO 'stamped.mrc' (FORMAT marc);
```

## 3. Authority cross-references: flipping bib headings to the 1XX

`marc_authority_refs(leader, fields)` reads one authority record into
`LIST(STRUCT(kind, tag, heading))` — `authorized` (1XX), `see_from` (4XX),
`see_also` (5XX); headings are the alphabetic subfield values joined with a
space ($w and $0-$9 excluded). `marc_heading_flips(bib_headings, auth_refs)`
then reports which of a bib record's headings NACO-match a see-from tracing,
paired with that authority's 1XX. The cross-record part is a SQL join you
write — the macros never see more than one record of each kind:

```sql
WITH auth AS (
    SELECT control_number AS auth_id,
           marc_authority_refs(leader, fields) AS refs
    FROM read_marc('authorities.mrc')
    WHERE marc_format(leader) = 'authority'),
bib AS (
    SELECT file, record_no, marc_headings(fields) AS headings
    FROM read_marc('bibs.mrc'))
SELECT b.file, b.record_no, a.auth_id,
       unnest(marc_heading_flips(b.headings, a.refs)) AS flip
FROM bib b
CROSS JOIN auth a
WHERE len(marc_heading_flips(b.headings, a.refs)) > 0;
-- flip.heading  = the obsolete form found in the bib
-- flip.authorized = the 1XX to flip it to
```

The cross join is quadratic; for production-size files pre-block it, e.g. by
joining on the first NACO token
(`ON split_part(marc_naco(...), ' ', 1) = ...`) before applying the macro.

## 4. Heading-change impact analysis

Which bib records are touched when a new authority snapshot changes 1XX
headings? Small macros (`marc_headings`, `marc_headings_naco` — main entries
100/110/111/130, all 6XX, added entries 700/710/711/730/740), the workflow in
SQL:

```sql
-- 4a. Authorized headings that disappeared between snapshots (EXCEPT)...
WITH old_h AS (
    SELECT unnest(marc_authority_refs(leader, fields)) AS r
    FROM read_marc('auth_2025.mrc')),
new_h AS (
    SELECT unnest(marc_authority_refs(leader, fields)) AS r
    FROM read_marc('auth_2026.mrc')),
gone AS (
    SELECT r.heading FROM old_h WHERE r.kind = 'authorized'
    EXCEPT
    SELECT r.heading FROM new_h WHERE r.kind = 'authorized')
-- 4b. ...joined against the bibs on NACO keys: every record still carrying
-- a heading that is no longer authorized.
SELECT b.file, b.record_no, b.control_number, g.heading AS obsolete_heading
FROM read_marc('bibs.mrc') b
JOIN gone g
  ON list_contains(marc_headings_naco(b.fields), marc_naco(g.heading))
ORDER BY b.file, b.record_no;
```

Pair with recipe 3 to propose the replacement: records whose obsolete heading
NACO-matches a see-from in the *new* snapshot get its 1XX as the fix.

## 5. 856 link audit

`marc_urls_856(fields)` extracts `LIST(STRUCT(uri, link_text, materials))`
from every 856 carrying a `$u` (first `$u`; `$y` preferred over `$z` for the
text; `$3` as materials). Checking the links pairs naturally with the
community `http_client` extension — **this extension does not depend on it**;
install it separately if you want in-database HTTP:

```sql
INSTALL http_client FROM community;
LOAD http_client;

WITH urls AS (
    SELECT file, record_no, control_number,
           unnest(marc_urls_856(fields)) AS u
    FROM read_marc('bibs.mrc')),
distinct_uris AS (SELECT DISTINCT u.uri FROM urls)
SELECT uri, (http_get(uri)).status AS status
FROM distinct_uris;             -- then join status back to urls for the report
```

(Check http_client's own docs for its exact return shape and rate behavior;
deduplicate URIs first, as above, to avoid hammering vendor hosts.)

Without any HTTP extension the same extraction still audits statically:
scheme distribution, duplicate URIs across records, 856s missing link text.

## 6. Fuzzy dedupe review

`marc_dedupe_key(fields)` is `marc_matchkey` under its workflow name
(NACO-normalized 245 $a $b first 40 code points `|` normalized ISBN `|`
year). Exact-key grouping is the cheap first pass:

```sql
SELECT marc_dedupe_key(fields) AS k, count(*), list(control_number)
FROM read_marc('bibs.mrc')
GROUP BY k HAVING count(*) > 1;
```

`marc_dedupe_candidates(path, threshold)` is the fuzzy second pass: every
unordered record pair of the file (or glob) scored by
`jaro_winkler_similarity` over NACO-normalized 245 $a titles. Pairs at or
above the threshold are kept — and exact match-key pairs are always included,
whatever the threshold. Columns: `file_a, record_no_a, file_b, record_no_b,
title_a, title_b, similarity, same_matchkey`.

```sql
SELECT * FROM marc_dedupe_candidates('bibs.mrc', 0.93)
ORDER BY similarity DESC;
```

Notes:
* records without a 245 $a score NULL similarity and surface only via
  `same_matchkey`;
* the self-join is quadratic — fine for review sets of a few thousand
  records. For big files, block first: group by `marc_dedupe_key` or a year/
  title-prefix key, then run pairwise scoring inside blocks with the same
  `jaro_winkler_similarity(marc_naco(a.title), marc_naco(b.title))`
  expression the macro uses.

## 7. RDA field check for AACR2-era records

Legacy records created under AACR2 are usually left untouched until they
resurface in copy cataloging or a batch project. `marc_rda_check(leader,
fields)` flags the fields most commonly overlooked (or still in AACR2 form),
as issue codes:

| code | meaning |
|---|---|
| `desc_aacr2` | Leader/18 = `a` — record still coded AACR2 |
| `no_040e_rda` | no 040 `$e rda` cataloging-convention marker |
| `missing_336` / `_337` / `_338` | RDA content/media/carrier types absent |
| `gmd_245h` | 245 `$h` GMD, deprecated in RDA in favor of the 33X trio |
| `only_260` | publication data in 260 with no 264 (RDA prefers 264) |
| `aacr2_abbreviations` | 250/300 abbreviations RDA spells out (`p.`, `v.`, `ill.`, `ed.`, ...) |
| `sl_sn_260` | `[S.l.]` / `[s.n.]`, replaced in RDA by `[Place of publication not identified]` etc. |
| `et_al_245` | `[et al.]` in the statement of responsibility |
| `no_relator_1xx` / `_7xx` | name entries with neither `$e` designator nor `$4` code |

Non-bibliographic records return an empty list. Profile a file first:

```sql
-- Which issues, how often?
SELECT issue, count(*) AS records,
       round(100.0 * count(*) / (SELECT count(*) FROM read_marc('bibs.mrc')), 1) AS pct
FROM (SELECT unnest(marc_rda_check(leader, fields)) AS issue
      FROM read_marc('bibs.mrc'))
GROUP BY issue ORDER BY records DESC;

-- Worklist: the records with the most to fix, worst first
SELECT record_no, control_number, marc_rda_check(leader, fields) AS issues
FROM read_marc('bibs.mrc')
WHERE len(marc_rda_check(leader, fields)) > 0
ORDER BY len(marc_rda_check(leader, fields)) DESC;
```

The mechanical fixes batch cleanly — `marc_generate_33x` derives the 33X trio
from the leader, `marc_rda_expand` spells out 250/300 abbreviations, the GMD
drops once the 33X fields exist, and Leader/18 flips to `i`:

```sql
COPY (
  SELECT substr(leader, 1, 18) || 'i' || substr(leader, 20) AS leader,
         marc_set_subfield(                        -- adds $e to the existing 040
           marc_rda_expand(
             marc_generate_33x(leader,
               marc_remove_subfield(fields, '245', 'h'))),
           '040', 'e', 'rda') AS fields
  FROM read_marc('bibs.mrc')
) TO 'bibs_rda.mrc' (FORMAT marc);
```

Re-running the profile on `bibs_rda.mrc` should leave only the judgment
calls, which want cataloger review rather than batch edits: `only_260`
(converting 260 to 264 means assigning the second indicator), `sl_sn_260` and
`et_al_245` (transcription decisions), and the relator flags (assigning
`$e author` vs `$e editor` needs the resource, or an authority lookup —
recipe 3 pairs well here). Notes:
* `marc_set_subfield` appends `$e rda` to an existing 040; for records
  without any 040, `marc_add_field` one first;
* run the fix only on flagged records (`WHERE len(marc_rda_check(...)) > 0`)
  to leave born-RDA copy untouched — every step is a no-op on clean records,
  so this is an optimization, not a correctness requirement.
