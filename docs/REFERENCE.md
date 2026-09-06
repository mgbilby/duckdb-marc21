# marc21 — function reference

Complete surface. The README carries the highlights; this file is the catalog.
`fields` always means the nested `LIST(STRUCT(tag, ind1, ind2, value, subfields))`
value produced by `read_marc()` and accepted by `COPY (FORMAT marc...)`.

## Table functions (readers)

| function | rows | notes |
|---|---|---|
| `marc_oai_token(url)` | one row | resumptionToken (NULL at the end of the list), completeListSize, cursor, expirationDate of one OAI response via `read_text` |
| `marc_readfields(path)` | field | subfields as a list, `control_value` for 00X |
| `marc_readfieldsbreaker(path)` | field | `marc_readfields` shape over `read_marc_breaker`: subfields as a list, `control_value` for 00X |
| `marc_readfieldsxml(path)` | field | `marc_readfields` shape over `read_marcxml`: subfields as a list, `control_value` for 00X |
| `marc_readnestedbreaker(path)` | record | the `read_marc` nested shape over `read_marc_breaker` |
| `marc_readnestedxml(path)` | record | the `read_marc` nested shape over `read_marcxml` |
| `marc_readoai(base, [metadata_prefix], [set_])` | subfield | OAI-PMH ListRecords, one response page; page onward with `marc_readoai_page` |
| `marc_readoai_page(base, resumption_token)` | subfield | OAI-PMH ListRecords follow-up page for a resumptionToken (LOAD httpfs); loop pattern in docs/LINKING.md |
| `marc_readsru(base, query, [max_records])` | subfield | builds an SRU searchRetrieve URL over `read_marcxml` (LOAD httpfs) |
| `read_alephseq(path, [tags])` | subfield | Aleph sequential |
| `read_marc(path, [encoding], [tags], [ignore_errors])` | record | nested `fields`; glob + gzip; parallel across and within files |
| `read_marc_breaker(path, [tags])` | subfield | `.mrk` mnemonic text; streamed |
| `read_marc_raw(path, [encoding])` | record | original BLOB + `error` column, never fails |
| `read_marc_subfields(path, ...)` | subfield | the analytical primitive; same parameters |
| `read_marcjson(path, [tags])` | subfield | MARC-in-JSON: object, array, NDJSON, FOLIO SRS envelopes |
| `read_marcxml(path, [tags])` | subfield | MARCXML slim; SRU/OAI envelopes handled; streamed |
| `read_microlif(path, [tags])` | subfield | MicroLIF vendor format (`.lif`); header and no-header variants |
| `read_z3950(host, port, database, query, [max_records], [timeout], [ignore_errors])` | record | live Z39.50 retrieval (see below) |

Every reader returns values in Unicode NFC, whatever the source used, so a
record read from MARC-8 compares equal to the same record read from
MARCXML. The consequence for round trips: decomposed input comes back
composed, so writing it out again preserves every value but not every byte
(`e` + combining acute becomes `é`, one byte shorter). `COPY ... (FORMAT
marc, NORMALIZE 'nfd')` writes decomposed output if a downstream system
needs it.

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
All four formats round-trip against their readers.

| format | writes | options |
|---|---|---|
| `marc` | ISO 2709 binary | `ENCODING`, `NORMALIZE` |
| `marcjson` | MARC-in-JSON | `NORMALIZE` |
| `marcxml` | MARCXML slim | `NORMALIZE` |
| `mrk` | breaker mnemonic text | `NORMALIZE` |

`ENCODING 'utf8'` (default) or `'marc8'` applies to `FORMAT marc` only;
`'marc8'` writes the full LC sets with escape designations (ANSEL, Cyrillic,
Greek, Hebrew, Arabic, EACC incl. Hangul; NCR `&#xHHHH;` only for characters
in no LC set).

`NORMALIZE 'nfc'` (default) or `'nfd'` selects the Unicode normalization of
written values; some legacy ILS loaders (Voyager/Aleph lineage, OCLC
"Unicode decomposed" profiles) expect NFD records.

UNIMARC: structural ISO 2709 reading works (pass `encoding := 'utf8'` —
UNIMARC does not declare UTF-8 in leader/09); field semantics and the
validation rulepacks stay MARC 21. Scope and worked examples:
[UNIMARC.md](UNIMARC.md).

## Navigation and addressing

| function | returns |
|---|---|
| `marc_008_struct(leader, fields)` | the 008 fixed field as a typed STRUCT (books sub-struct when applicable) |
| `marc_control_field(fields, tag)` | the value of the first control field carrying that tag |
| `marc_fields(fields, tag)` | the field structs carrying that tag |
| `marc_leader_struct(leader)` | the leader's fixed positions as a typed STRUCT |
| `marc_spec(leader, fields, spec)` | MARCspec subset: `245$a$b`, `6..`, `LDR/6`, `008/35-37`, `[i]`, `[#]`, `^1` |
| `marc_subfield(fields, tag, code)` | the first value of that subfield |
| `marc_subfields(fields, tag, code)` | every value of that subfield, as a list |

## Positional helpers

| function | returns |
|---|---|
| `marc_bib_level(leader)` | Leader/07, the bibliographic-level code |
| `marc_control_pos(val, start_pos, len)` | `len` characters of a control field's value from 0-based position `start_pos` |
| `marc_encoding_scheme(leader)` | `utf8` or `marc8`, read from Leader/09 |
| `marc_format(leader)` | the MARC 21 format the record is in, derived from Leader/06: `bibliographic`, `authority`, `holdings`, `classification` or `community` |
| `marc_leader_pos(leader, pos)` | the single leader character at 0-based position `pos` |
| `marc_record_type(leader)` | Leader/06, the type-of-record code |

## Validation

| function | notes |
|---|---|
| `marc_folio_check(leader, fields)` | FOLIO data-import expectations (001/003, 999 ff reserved, UTF-8) |
| `marc_validate(leader, fields)` | structural checks; 245 rule gated to bibliographic records |
| `marc_validate_auth(leader, fields)` | the embedded MARC 21 authority rulepack from `schemas/*.avram.json` |
| `marc_validate_avram(leader, fields, schema_json)` | any Avram-subset schema; constant schemas parse once at bind |
| `marc_validate_bib(leader, fields)` | the embedded MARC 21 bibliographic rulepack from `schemas/*.avram.json` |
| `marc_validate_format(leader, fields)` | the embedded rulepack for the record's own format, dispatched on Leader/06 |
| `marc_validate_holdings(leader, fields)` | the embedded MARC 21 holdings rulepack from `schemas/*.avram.json` |

Rulepack macros are generated from the Avram schemas in `schemas/`.

## Editing (fields in, fields out — compose in UPDATE/SELECT)

| function | notes |
|---|---|
| `marc_add_field(fields, field_struct)` | insert one field struct into the record |
| `marc_diff(leader_a, fields_a, leader_b, fields_b)` | the field-level differences between two records |
| `marc_merge(base, incoming, protected_csv, replace_csv, add_csv, 'keep'\|'replace'\|'add')` | merge `incoming` into `base` under the per-tag protected / replace / add lists and a default policy for everything else |
| `marc_remove_fields(fields, tagpat)` | delete every field matching the tag pattern |
| `marc_remove_subfield(fields, tagpat, code)` | delete that subfield code from every matching field |
| `marc_replace_all(fields, rules)` | a whole rules table applied in order — `rules` is `LIST(STRUCT(tag, code, find, replace))`, NULL code = every code; aggregate a CSV of rules with `list(struct_pack(...))` for MarcEdit's replace-from-external-list |
| `marc_replace_values(fields, tagpat, code_or_null, regex, replacement)` | regex replacement over matching subfield values; NULL `code_or_null` means every code |
| `marc_set_indicators(fields, tagpat, ind1, ind2)` | set both indicators on every matching field |
| `marc_set_subfield(fields, tagpat, code, value)` | set that subfield's value on every matching field, appending it where it is missing |

Tag patterns use `.` wildcards (`6..`).

### Field surgery

| function | notes |
|---|---|
| `marc_264_from_260(fields)` | RDA 264 _1/_4 pair generated from a 260, in place |
| `marc_build_field(leader, fields, template)` | a field built from a breaker-line template with `{tag$code}` placeholders |
| `marc_change_case(fields, tagpat, code_or_'*', 'upper'\|'lower'\|'title')` | recase matching values (ASCII + Latin-1; control fields untouched) |
| `marc_check_urls(path)` | table macro: the URL audit worklist for a whole file |
| `marc_copy_field(fields, tagpat, new_tag)` | copies of the matching fields under `new_tag`, inserted in tag order |
| `marc_move_field(fields, from_tagpat, to_tag)` | renumber in place, order and indicators kept |
| `marc_remove_fields_where(fields, tagpat, code, regex, [icase])` | delete fields whose subfield matches the regex |
| `marc_rename_subfield(fields, tagpat, from_code, to_code)` | $x → $z within matching data fields, values and subfield order kept |
| `marc_sort_fields(fields)` | stable tag sort — same tag keeps occurrence order |
| `marc_swap_fields(fields, tag_a, tag_b)` | exchange the two tags in place — every `tag_a` field becomes `tag_b` and vice versa, order and indicators kept; literal tags on the same side of the control/data boundary |

### Linked-data write-back

Writing authority and real-world-object URIs back into the records
(docs/LINKING.md):

| function | notes |
|---|---|
| `marc_clear_linked_uris(fields, tagpat, '0'\|'1')` | removes every such link from the matching tags |
| `marc_set_linked_uri(fields, tagpat, heading, uri, '0'\|'1')` | sets `$0`/`$1` to `uri` on every field matching `tagpat` whose joined heading (the `marc_heading_join` rule) NACO-equals `heading` — an existing link is replaced in place, otherwise the subfield is appended at the field's end; no match is a no-op |

### Clustering

| function | notes |
|---|---|
| `marc_cluster_headings(path, 'fingerprint'\|'ngram')` | table macro: a file's headings grouped by shared key |
| `marc_fingerprint(v)` | the OpenRefine-style key-collision key of one value |
| `marc_ngram_fingerprint(v, n)` | the OpenRefine-style n-gram key of one value |

### Authority reconciliation

Fetch-then-shape: the extension builds the lookup URLs and shapes the
responses, the fetch between them is yours (see src/macros/reconcile.sql).

| function | notes |
|---|---|
| `marc_idloc_candidates(j)` | response shaper: candidate rows out of one id.loc.gov response, over `read_json` |
| `marc_idloc_label_url(label, [scheme])` | URL builder: an id.loc.gov label lookup |
| `marc_idloc_suggest_url(term, [scheme], [count_])` | URL builder: an id.loc.gov suggest query |
| `marc_oai_extract_token(xml)` | the resumptionToken out of one OAI response document |
| `marc_oai_page_url(base, resumption_token)` | URL builder: the OAI-PMH ListRecords follow-up page for a token |
| `marc_oai_url(base, [metadata_prefix], [set_], [from_], [until_])` | URL builder: the first OAI-PMH ListRecords page for a prefix, set and date window |
| `marc_reconcile_headings(path, base)` | table macro: the lookup queue — one row per distinct heading with its occurrence count and URL |
| `marc_viaf_candidates(j)` | response shaper: candidate rows out of one VIAF response, over `read_json` |
| `marc_viaf_search_url(term, [index_], [max_records])` | URL builder: a VIAF search |
| `marc_wikidata_candidates(j)` | response shaper: candidate rows out of one Wikidata response, over `read_json` |
| `marc_wikidata_search_url(term, [language], [limit_])` | URL builder: a Wikidata entity search |

## Identifiers, headings, dedupe

| function | returns |
|---|---|
| `marc_dedupe_candidates(path, threshold)` | table macro: exact matchkey pairs plus Jaro-Winkler title similarity above `threshold` |
| `marc_dedupe_key(fields)` | the `marc_matchkey` dedupe key under its workflow name |
| `marc_heading_join(field)` | one heading string for a field, `$w`/`$0-$9` excluded |
| `marc_headings(fields)` | the record's 1XX/6XX/7XX heading list, linking entries excluded |
| `marc_headings_naco(fields)` | the same heading list in NACO comparison form |
| `marc_isbn13(v)` | the value normalized as an ISBN-13; NULL when invalid |
| `marc_issn(v)` | the value normalized as an ISSN; NULL when invalid |
| `marc_lccn(v)` | the value normalized as an LCCN; NULL when invalid |
| `marc_matchkey(fields)` | title+ISBN+date dedupe key, aliased as `marc_dedupe_key` |
| `marc_naco(v)` | the NACO comparison form of the value |
| `marc_oclc(v)` | the value normalized as an OCLC number; NULL when invalid |

## Cataloging helpers

| function | returns |
|---|---|
| `marc_add_local(fields, tag, i1, i2, codes, values)` | local-field templating: a data field built from parallel code/value lists, inserted in tag order |
| `marc_authority_refs(leader, fields)` | LIST(STRUCT(kind, tag, heading)): 1XX/4XX/5XX of an authority record |
| `marc_cutter_valid(cutter)` | Cutter-number shape check |
| `marc_ddc_sortkey(callnum)` | shelflist-order sort key for a Dewey call number |
| `marc_generate_33x(leader, fields)` | fields + RDA 336/337/338 derived from the leader, 008/26, the 006 fields when the leader is ambiguous, and 007/00-01 for media and the specific carrier (videocassette vs videodisc, audiocassette vs audio disc, tactile text, still image for projected graphics) |
| `marc_heading_flips(bib_headings, auth_refs)` | see-from matches → LIST(STRUCT(heading, authorized)) |
| `marc_lcc_parse(callnum)` | STRUCT(class, number, decimal, cutters, year, rest, valid) |
| `marc_lcc_sortkey(callnum)` | shelflist-order sort key for an LC call number |
| `marc_new_record(material)` | STRUCT(leader, fields) skeleton: `book`, `serial`, `video`, `map`, `music`, `electronic`, `authority` (Leader/06 z, authority 008, empty 100 $a) |
| `marc_rank(leader, fields)` | STRUCT(encoding_level_rank, completeness, total) — pick the fuller record |
| `marc_rda_check(leader, fields)` | LIST(VARCHAR) of AACR2-era issues (missing 33X, GMD, 260-only, abbreviations, relators, ...) — see RECIPES.md §7 |
| `marc_rda_expand(fields)` | AACR2 abbreviations expanded to RDA forms in transcription fields |
| `marc_stamp(fields, org_code)` | the 949 load stamp: `$a org_code` plus the load date in `$d` |
| `marc_urls_856(fields)` | LIST(STRUCT(uri, link_text, materials)) for link audits |

## Acquisitions: KBART

| function | returns |
|---|---|
| `marc_kbart_856(title_url, link_text)` | an 856 40 field struct |
| `marc_kbart_to_marc(publication_title, online_identifier, title_url, publisher_name)` | a brief STRUCT(leader, fields) e-resource record: 020/022 chosen by identifier validity, 245, 260, 856 |
| `marc_read_kbart(path)` | table macro: a tab-separated KBART title list, columns as-is |

End-to-end workflows: [RECIPES.md](RECIPES.md).

## Acquisitions: delimited text (spreadsheets)

The MarcEdit "Delimited Text Translator" equivalent.

| function | returns |
|---|---|
| `marc_from_delimited(material, mapping)` | a STRUCT(leader, fields) record per spreadsheet row: the skeleton comes from `marc_new_record(material)`, the mapping is a list of one-struct-per-cell `{tag, i1, i2, code, value}` entries |
| `marc_from_delimited_url(material, mapping, url, link_text)` | the same record with an 856 40 appended via `marc_kbart_856` |

Entries sharing (tag, i1, i2) merge into one field with subfields in mapping
order; blank/NULL cells drop their subfield (and an emptied field
disappears); tags below 010 become control fields; NULL i1/i2 mean blank,
NULL code means $a; fields land in tag order.

```sql
SELECT marc_from_delimited('book', [
           {tag: '245', i1: '1', i2: '0', code: 'a', value: title},
           {tag: '100', i1: '1', i2: NULL::VARCHAR, code: 'a', value: author},
           {tag: '020', i1: NULL::VARCHAR, i2: NULL::VARCHAR, code: 'a', value: isbn::VARCHAR}
       ]) AS r
FROM read_csv('titles.csv');
```

Cast sniffed columns to VARCHAR (an ISBN column read as BIGINT, a bare
`NULL` indicator) or the struct list cannot unify; `read_csv(...,
all_varchar := true)` sidesteps it for whole spreadsheets.

Preset mappings for common layouts — each returns the mapping list, so they
compose with both translators (append extra entries with `||`):

| function | returns |
|---|---|
| `marc_delimited_preset_books(title, author, isbn, publisher, pubyear)` | the mapping list for a book layout: 100/245/020 plus one 264 _1; 245 ind1 tracks the author column |
| `marc_delimited_preset_eresources(title, url, isbn)` | the mapping list for an e-resource layout: 245/856 40/020 |
| `marc_delimited_preset_serials(title, issn, publisher)` | the mapping list for a serial layout: 245/022/264 _1 |

There is deliberately no `marc_delimited_preset(name, ...)` dispatcher: a
SQL macro has a fixed argument list, so one macro cannot take five columns
for books but three for serials — call the preset for your layout.

Worked round trip: test/sql/marc_delimited.test; presets:
test/sql/marc_editing3.test.

## Reports and summaries (table macros)

| macro | one row per |
|---|---|
| `marc_report_completeness(path)` | record: has_* flags + weighted 0-100 score |
| `marc_report_errors(path)` | violation (unnested) |
| `marc_report_subfields(path, tag)` | code: frequency within that tag |
| `marc_report_tags(path)` | tag: frequency across the file |
| `marc_summary(path)` | corpus: totals + min/max/mean/stddev of fields, subfields, tags per record |
| `marc_summary_fields(path)` | tag: coverage pct + occurrence distributions |
| `marc_summary_subfields(path, tag)` | code: counts + value-length stats |

## Crosswalks and linked data

| function | returns |
|---|---|
| `marc_dublin_core(leader, fields)` | the record as simple Dublin Core elements |
| `marc_ids_fast(fields)` | the `$0`/`$1` values that are OCLC FAST identifiers |
| `marc_ids_lc(fields)` | the `$0`/`$1` values that are id.loc.gov identifiers |
| `marc_ids_viaf(fields)` | the `$0`/`$1` values that are VIAF identifiers |
| `marc_instance(leader, fields)` | a FOLIO-instance-shaped STRUCT |
| `marc_jsonld(leader, fields)` | a schema.org-flavored JSON-LD object: `@type` from Leader/06-07 — Book/Periodical/Map/Movie/MusicComposition/... — name/author/publisher/datePublished/inLanguage/about via the `marc_dublin_core` crosswalk, `isbn`/`issn` through `marc_isbn13`/`marc_issn` of 020$a/022$a, `url` from 856$u, `sameAs` from $0/$1 URIs; keys with no source data are absent, not null |
| `marc_mods_xml(leader, fields)` | the record as MODS XML |
| `marc_parse_json(json)` | MARC-in-JSON / FOLIO SRS → STRUCT(leader, fields); see docs/FOLIO.md |
| `marc_type_of_resource(leader)` | the type-of-resource term for Leader/06 |
| `marc_uris(fields)` | the record's `$0`/`$1` URIs, as LIST(STRUCT(tag, code, uri)) |

One `marc_jsonld` object per record makes NDJSON:

```sql
COPY (SELECT marc_jsonld(leader, fields)::VARCHAR AS line
      FROM read_marc('bibs.mrc'))
TO 'bibs.jsonld' (FORMAT csv, HEADER false, QUOTE '');
```

### XSLT crosswalk registry

The shipped XSLT crosswalks and their catalog (`xslt/registry.tsv`) are
embedded in the extension binary, so an alias resolves with no files on disk.
The extension catalogs and hands out stylesheets; running one is `xsltproc`,
Saxon or the browser (docs/ECOSYSTEM.md).

| function | returns | notes |
|---|---|---|
| `marc_xslt_command(alias, input_path, output_path)` | VARCHAR | the `xsltproc` command line for that crosswalk, all three paths shell-quoted; NULL for an unknown alias |
| `marc_xslt_functions()` | one row per shipped crosswalk | `alias`, `path`, `source_format`, `target_format`, `description`; formats are MARC, MARC-AUTHORITY, MODS, OAI_DC, DCTERMS, RDF-DC, EAD3, HTML, JSON-LD, RIS, UNIMARC, ONIX3, EDM, MADS, BIBFRAME2 |
| `marc_xslt_library()` | VARCHAR | the shared `lib/marc-utils.xsl` text every sheet includes |
| `marc_xslt_sheet_file(alias_or_path)` | VARCHAR | the sheet's bare filename — the name to export it as |
| `marc_xslt_stylesheet(alias_or_path)` | VARCHAR | the stylesheet text; alias matched case-insensitively, registry path accepted too; NULL when the key is not registered |

A stylesheet carries newlines and quotation marks, so export it with quoting
and escaping switched off, trimming the text's own final newline so the CSV
row terminator supplies exactly one:

```sql
COPY (SELECT rtrim(marc_xslt_stylesheet('MARC=>MODS'), chr(10)))
  TO 'work/marcxml-to-mods.xsl' (FORMAT csv, HEADER false, QUOTE '', ESCAPE '');
```

Aliases, the export workflow, a local user registry and the browser case:
[XSLT.md](XSLT.md).

## Serials

| function | returns |
|---|---|
| `marc_expand_863(caption_field, value_field)` | one caption:value rendering of a caption/value field pair |
| `marc_holdings_pairs(fields)` | the record's 853/863-family holdings pairs, matched on `$8` |

## Rendering

| function | returns |
|---|---|
| `marc_fieldbreak(field)` | one field as a breaker line |
| `marc_recordbreak(leader, fields)` | one whole record as breaker text |
