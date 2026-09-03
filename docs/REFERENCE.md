# marc21 — function reference

Complete surface. The README carries the highlights; this file is the catalog.
`fields` always means the nested `LIST(STRUCT(tag, ind1, ind2, value, subfields))`
value produced by `read_marc()` and accepted by `COPY (FORMAT marc...)`.

## Table functions (readers)

| function | rows | notes |
|---|---|---|
| `read_marc(path, [encoding], [tags], [ignore_errors])` | record | nested `fields`; glob + gzip; parallel across and within files |
| `read_marc_subfields(path, ...)` | subfield | the analytical primitive; same parameters |
| `read_marc_raw(path, [encoding])` | record | original BLOB + `error` column, never fails |
| `read_marcxml(path, [tags])` | subfield | MARCXML slim; SRU/OAI envelopes handled; streamed |
| `read_marc_breaker(path, [tags])` | subfield | `.mrk` mnemonic text; streamed |
| `read_marcjson(path, [tags])` | subfield | MARC-in-JSON: object, array, NDJSON, FOLIO SRS envelopes |
| `read_alephseq(path, [tags])` | subfield | Aleph sequential |
| `marc_readsru(base, query, [max_records])` | subfield | builds an SRU searchRetrieve URL over `read_marcxml` (LOAD httpfs) |
| `marc_readoai(base, [metadata_prefix], [set_])` | subfield | OAI-PMH ListRecords, one response page |
| `read_z3950(host, port, database, query, [max_records], [timeout], [ignore_errors])` | record | live Z39.50 retrieval (see below) |
| `marc_readfields(path)` | field | subfields as a list, `control_value` for 00X |
| `marc_readnestedxml` / `marc_readnestedbreaker` / `marc_readfieldsxml` / `marc_readfieldsbreaker` | record/field | nested shapes over the text readers |

### read_z3950

An independently implemented Z39.50-1995 client (Init → Search → Present, Type-1 RPN with
Bib-1 attributes, USMARC syntax) over plain TCP — no external dependencies.
Works against the Library of Congress (`z3950.loc.gov`, 7090, `VOYAGER`) and
most ILS servers. One row per returned record in the `read_marc` nested shape
plus a `hits` column (the server's total); `max_records` defaults to 10,
`timeout` (seconds) to 15. Queries are a term with optional `@attr` pairs:

```sql
SELECT hits, marc_subfield(fields, '245', 'a') AS title
FROM read_z3950('z3950.loc.gov', 7090, 'VOYAGER', '@attr 1=7 0316769487');
```

Useful Bib-1 use attributes: `1=4` title, `1=7` ISBN, `1=12` local number,
`1=1016` any (the default for a bare term). Requires
`enable_external_access`.

## Writers

`COPY (SELECT ... leader, fields ...) TO 'f' (FORMAT marc | marcxml | mrk | marcjson)`.
`FORMAT marc` takes `ENCODING 'utf8'` (default) or `'marc8'` (full LC sets with
escape designations: ANSEL, Cyrillic, Greek, Hebrew, Arabic, EACC incl. Hangul;
NCR `&#xHHHH;` only for characters in no LC set). All formats round-trip
against their readers.

## Navigation and addressing

| function | returns |
|---|---|
| `marc_fields(fields, tag)` / `marc_subfields(fields, tag, code)` / `marc_subfield(...)` / `marc_control_field(fields, tag)` | field structs / value lists / first value |
| `marc_spec(leader, fields, spec)` | MARCspec subset: `245$a$b`, `6..`, `LDR/6`, `008/35-37`, `[i]`, `[#]`, `^1` |
| `marc_leader_pos` / `marc_control_pos` / `marc_record_type` / `marc_bib_level` / `marc_encoding_scheme` / `marc_format` | positional helpers; format from Leader/06 |
| `marc_leader_struct(leader)` / `marc_008_struct(leader, fields)` | fixed fields as typed STRUCTs (books sub-struct when applicable) |

## Validation

| function | notes |
|---|---|
| `marc_validate(leader, fields)` | structural checks; 245 rule gated to bibliographic records |
| `marc_validate_avram(leader, fields, schema_json)` | any Avram-subset schema; constant schemas parse once at bind |
| `marc_validate_bib` / `_auth` / `_holdings` / `_format` | embedded MARC 21 rulepacks from `schemas/*.avram.json`; `_format` dispatches on Leader/06 |
| `marc_folio_check(leader, fields)` | FOLIO data-import expectations (001/003, 999 ff reserved, UTF-8) |

Rulepack macros are generated from the Avram schemas in `schemas/`.

## Editing (fields in, fields out — compose in UPDATE/SELECT)

`marc_add_field(fields, field_struct)`, `marc_remove_fields(fields, tagpat)`,
`marc_remove_subfield(fields, tagpat, code)`, `marc_set_subfield(fields, tagpat, code, value)`,
`marc_replace_values(fields, tagpat, code_or_null, regex, replacement)`,
`marc_set_indicators(fields, tagpat, ind1, ind2)`,
`marc_merge(base, incoming, protected_csv, replace_csv, add_csv, 'keep'|'replace'|'add')`,
`marc_diff(leader_a, fields_a, leader_b, fields_b)`.
Tag patterns use `.` wildcards (`6..`).

## Identifiers, headings, dedupe

`marc_isbn13`, `marc_issn`, `marc_lccn`, `marc_oclc` (normalize; NULL when
invalid), `marc_naco` (NACO comparison form), `marc_matchkey(fields)`
(title+ISBN+date dedupe key, aliased as `marc_dedupe_key`).

`marc_headings(fields)` / `marc_headings_naco(fields)` (1XX/6XX/7XX heading
lists, linking entries excluded), `marc_heading_join(field)` (one heading
string, `$w`/`$0-$9` excluded), and the table macro
`marc_dedupe_candidates(path, threshold)` (exact matchkey pairs plus
Jaro-Winkler title similarity above `threshold`).

## Cataloging helpers

| function | returns |
|---|---|
| `marc_rank(leader, fields)` | STRUCT(encoding_level_rank, completeness, total) — pick the fuller record |
| `marc_new_record(material)` | STRUCT(leader, fields) skeleton: `book`, `serial`, `video`, `map`, `music`, `electronic` |
| `marc_rda_expand(fields)` | AACR2 abbreviations expanded to RDA forms in transcription fields |
| `marc_generate_33x(leader, fields)` | fields + RDA 336/337/338 derived from the leader |
| `marc_rda_check(leader, fields)` | LIST(VARCHAR) of AACR2-era issues (missing 33X, GMD, 260-only, abbreviations, relators, ...) — see RECIPES.md §7 |
| `marc_lcc_parse(callnum)` | STRUCT(class, number, decimal, cutters, year, rest, valid) |
| `marc_lcc_sortkey` / `marc_ddc_sortkey` | shelflist-order sort keys |
| `marc_cutter_valid(cutter)` | Cutter-number shape check |
| `marc_authority_refs(leader, fields)` | LIST(STRUCT(kind, tag, heading)): 1XX/4XX/5XX of an authority record |
| `marc_heading_flips(bib_headings, auth_refs)` | see-from matches → LIST(STRUCT(heading, authorized)) |
| `marc_add_local(fields, tag, i1, i2, codes, values)` / `marc_stamp(fields, org_code)` | local-field templating; 949 date stamp |
| `marc_urls_856(fields)` | LIST(STRUCT(uri, link_text, materials)) for link audits |

## Acquisitions: KBART

`marc_read_kbart(path)` (tab-separated KBART title list, columns as-is),
`marc_kbart_856(title_url, link_text)` (an 856 40 field struct),
`marc_kbart_to_marc(publication_title, online_identifier, title_url,
publisher_name)` (a brief STRUCT(leader, fields) e-resource record: 020/022
chosen by identifier validity, 245, 260, 856). End-to-end workflows:
[RECIPES.md](RECIPES.md).

## Reports and summaries (table macros)

| macro | one row per |
|---|---|
| `marc_summary(path)` | corpus: totals + min/max/mean/stddev of fields, subfields, tags per record |
| `marc_summary_fields(path)` | tag: coverage pct + occurrence distributions |
| `marc_summary_subfields(path, tag)` | code: counts + value-length stats |
| `marc_report_tags(path)` / `marc_report_subfields(path, tag)` | tag / code frequency |
| `marc_report_completeness(path)` | record: has_* flags + weighted 0-100 score |
| `marc_report_errors(path)` | violation (unnested) |

## Crosswalks and linked data

`marc_instance(leader, fields)` (FOLIO-instance-shaped STRUCT),
`marc_dublin_core(leader, fields)`, `marc_mods_xml(leader, fields)`,
`marc_type_of_resource(leader)`, `marc_uris(fields)` ($0/$1 URIs),
`marc_ids_lc` / `marc_ids_viaf` / `marc_ids_fast`,
`marc_parse_json(json)` (MARC-in-JSON / FOLIO SRS → STRUCT(leader, fields); see docs/FOLIO.md).

## Serials

`marc_holdings_pairs(fields)` (853/863-family pairing on $8),
`marc_expand_863(caption_field, value_field)` (caption:value rendering).

## Rendering

`marc_fieldbreak(field)`, `marc_recordbreak(leader, fields)` (breaker text).
