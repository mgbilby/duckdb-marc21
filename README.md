# MARC21 Cataloging Toolkit for DuckDB

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![GitHub Release](https://img.shields.io/github/v/release/mgbilby/duckdb-marc21)
![GitHub Actions Workflow Status](https://img.shields.io/github/actions/workflow/status/mgbilby/duckdb-marc21/.github%2Fworkflows%2FMainDistributionPipeline.yml)
[![DuckDB](https://img.shields.io/static/v1?label=duckdb&message=v1.5.4%2B&color=blue)](https://github.com/duckdb/duckdb/releases)
[![Community downloads per week](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fcommunity-extensions.duckdb.org%2Fdownloads-last-week.json&query=%24.marc21&label=downloads%2Fweek&color=brightgreen)](https://duckdb.org/community_extensions/download_metrics)

Read, write, validate, edit, and analyze [MARC 21](https://www.loc.gov/marc/bibliographic/)
bibliographic data with DuckDB, using filetypes, APIs and catalogs you already know.

| area | coverage | representative functions |
|---|---|---|
| **Read** | [ISO 2709](https://www.loc.gov/marc/specifications/specrecstruc.html) binary (UTF-8 and [MARC-8](https://www.loc.gov/marc/specifications/speccharintro.html), decoded to NFC), [MARCXML](https://www.loc.gov/standards/marcxml/), [MARC-in-JSON](https://www.loc.gov/standards/mij/), breaker `.mrk`, Aleph sequential, MicroLIF — nested per record or one row per subfield | `read_marc`, `read_marc_subfields`, `read_marc_raw`, `read_marcxml`, `read_marcjson`, `read_marc_breaker`, `read_alephseq`, `read_microlif` |
| **Retrieve** | live records over SRU, OAI-PMH with resumption-token paging, and [Z39.50](https://www.loc.gov/z3950/agency/) via a built-in dependency-free client | `read_z3950`, `marc_readsru`, `marc_readoai`, `marc_readoai_page` |
| **Write** | every read format written back through `COPY`, with a complete UTF-8 ↔ MARC-8 crosswalk (ANSEL, Cyrillic, Greek, Hebrew, Arabic, EACC with escape designations) | `COPY … (FORMAT marc \| marcxml \| mrk \| marcjson)` |
| **Address** | [MARCspec](https://marcspec.github.io/MARCspec/) expressions, subfield and field accessors, leader and 008 positional decoding | `marc_spec`, `marc_subfield`, `marc_subfields`, `marc_fields`, `marc_leader_struct`, `marc_008_struct` |
| **Validate** | structural checks by record type plus [Avram](https://format.gbv.de/schema/avram/specification) schema validation against embedded bibliographic, authority and holdings rulepacks | `marc_validate`, `marc_validate_bib`, `marc_validate_auth`, `marc_validate_holdings`, `marc_validate_avram`, `marc_validate_format` |
| **Edit** | field and subfield surgery, indicator and case changes, reordering, merge with field protection, record diff, RDA 264 derivation | `marc_set_subfield`, `marc_add_field`, `marc_move_field`, `marc_swap_fields`, `marc_set_indicators`, `marc_sort_fields`, `marc_merge`, `marc_diff`, `marc_264_from_260` |
| **Identify & dedupe** | ISBN/ISSN/LCCN/OCLC normalization, NACO headings, match keys, fingerprint and n-gram clustering, candidate review | `marc_isbn13`, `marc_issn`, `marc_lccn`, `marc_oclc`, `marc_naco`, `marc_matchkey`, `marc_fingerprint`, `marc_ngram_fingerprint`, `marc_dedupe_candidates`, `marc_cluster_headings` |
| **Catalog** | RDA checks and expansion, 33X generation, call-number parsing and shelf sorting, record scaffolding | `marc_rda_check`, `marc_rda_expand`, `marc_generate_33x`, `marc_lcc_parse`, `marc_lcc_sortkey`, `marc_ddc_sortkey`, `marc_cutter_valid`, `marc_new_record` |
| **Report** | whole-file profiling: tag and subfield frequency, completeness, error rollups, URL audits | `marc_report_tags`, `marc_report_subfields`, `marc_report_completeness`, `marc_report_errors`, `marc_summary`, `marc_check_urls` |
| **Crosswalk & link** | Dublin Core, MODS, [BIBFRAME](https://www.loc.gov/bibframe/) 2.x JSON-LD, ISBD, UNIMARC labels, plus a 28-stylesheet embedded XSLT 1.0 library you can query and extend | `marc_dublin_core`, `marc_mods_xml`, `marc_bibframe_jsonld`, `marc_jsonld`, `marc_isbd`, `marc_unimarc_label`, `marc_xslt_functions` |
| **Connect to ILSs** | [FOLIO](https://folio.org/) Source Record Storage, Alma (read and bib write-back), Koha, WorldShare — composed from URLs and SQL, no vendor SDKs | `marc_readfolio_srs`, `marc_parse_json`, `marc_readalma_bibs`, `marc_alma_update_bib`, `marc_readkoha`, `marc_readworldshare` |
| **Accession** | [KBART](https://www.niso.org/standards-committees/kbart) title lists in and out, and spreadsheet-to-MARC mapping with presets for books, serials and e-resources | `marc_read_kbart`, `marc_kbart_to_marc`, `marc_kbart_856`, `marc_from_delimited`, `marc_delimited_preset_books` |
| **Reconcile** | authority candidate lookup against VIAF, id.loc.gov and Wikidata | `marc_viaf_candidates`, `marc_idloc_candidates`, `marc_wikidata_candidates`, `marc_reconcile_headings` |
| **Serials** | 863–865 enumeration expansion and holdings pairing | `marc_expand_863`, `marc_holdings_pairs`, `marc_86x_zip` |

Full documentation in [`docs/REFERENCE.md`](docs/REFERENCE.md).

- Pure C++ leverages the speed and power of DuckDB
- Read Gzip and glob patterns (`catalogue/*.mrc.gz`), parallelize operations in files, and skip character decoding for unselected columns 
- Built from ISO 2709 and Library of Congress specifications, not prior
  software (see [`audit/`](audit/).
- `read_z3950` needs OS-level networking and is unavailable in browser-based builds.

## Installation

marc21 is a DuckDB Community Extension.

To install and use the extension, run these SQL commands in your DuckDB session:
```
INSTALL marc21 FROM community;
LOAD marc21;
```
That's it!

## Quick start
```
-- Read a catalog dump, auto-detect record encodings, decoded to NFC
D SELECT control_number, marc_subfield(fields, '245', 'a') AS title
  FROM read_marc('catalogue.mrc') LIMIT 3;
┌────────────────┬──────────────────────┐
│ control_number │        title         │
│    varchar     │       varchar        │
├────────────────┼──────────────────────┤
│ ocm00000001    │ Łódź and the river : │
│ ocm00000002    │ 日本の歴史 /           │
│ ocm00000003    │ The empty record.    │
└────────────────┴──────────────────────┘

-- One row per subfield: frequency, completeness, QA
D SELECT tag, code, count(*) AS n
  FROM read_marc_subfields('catalogue.mrc')
  GROUP BY ALL ORDER BY n DESC, tag, code LIMIT 4;
┌─────────┬─────────┬───────┐
│   tag   │  code   │   n   │
│ varchar │ varchar │ int64 │
├─────────┼─────────┼───────┤
│ 880     │ a       │     4 │
│ 001     │ NULL    │     1 │
│ 245     │ a       │     1 │
│ 880     │ 6       │     1 │
└─────────┴─────────┴───────┘

-- Query anything MARCspec-style; validate against embedded rulepacks
SELECT marc_spec(leader, fields, '008/35-37') FROM read_marc('dump.mrc');
SELECT marc_validate_format(leader, fields)   FROM read_marc('dump.mrc');

-- Batch-edit and write back, with a full MARC-8/UTF-8 crosswalk
COPY (SELECT leader, marc_set_subfield(fields, '040', 'a', 'XX-XxUND') AS fields
      FROM read_marc('in.mrc'))
TO 'out.mrc' (FORMAT marc, ENCODING 'marc8');

-- Retrieve straight from a Z39.50 server (LC, OCLC, most ILSes)
SELECT hits, marc_subfield(fields, '245', 'a') AS title
FROM read_z3950('z3950.loc.gov', 7090, 'VOYAGER', '@attr 1=7 0316769487');
```

Full documentation for all the functions can be found in [docs/REFERENCE.md](docs/REFERENCE.md). Workflow recipes (KBART loads, authority flips, heading-change impact, link audits, fuzzy dedupe) are in [docs/RECIPES.md](docs/RECIPES.md), and the FOLIO connector pattern in [docs/FOLIO.md](docs/FOLIO.md).

## Building
### Managing dependencies
The extension is pure C++17 with no external dependencies — no VCPKG setup is needed.

### Build steps
To build the extension, first clone this repo. Then in the repo base locally run:

```sh
git submodule update --init --recursive
```
To get the source for DuckDB and CI-tools. Next run:

```sh
make
```
If you have ninja available you can use that for faster builds:
```sh
GEN=ninja make
```
The main binaries that will be built are:
```sh
./build/release/duckdb
./build/release/test/unittest
./build/release/extension/marc21/marc21.duckdb_extension
```
- `duckdb` is the binary for the duckdb shell with the extension code automatically loaded.
- `unittest` is the test runner of duckdb. Again, the extension is already linked into the binary.
- `marc21.duckdb_extension` is the loadable binary as it would be distributed.

## Cleanliness

Use `make format` to format all code to the DuckDB standards, `make tidy-check` to lint.

## Running the extension
To run the extension code, simply start the shell with `./build/release/duckdb`.

## Running the tests
Tests for this extension are SQL tests in `./test/sql`. They rely on samples in the `test/data` directory. These SQL tests can be run using:
```sh
make test
```
The parser, decoder, writer and Z39.50 core also have standalone C++ suites that need no DuckDB build:
```sh
make core_test
```

This repository is based on https://github.com/duckdb/extension-template, check it out if you want to build and ship your own DuckDB extension.
