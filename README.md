# MARC21 Cataloging Toolkit for DuckDB

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![GitHub Release](https://img.shields.io/github/v/release/mgbilby/duckdb-marc21)
![GitHub Actions Workflow Status](https://img.shields.io/github/actions/workflow/status/mgbilby/duckdb-marc21/.github%2Fworkflows%2FMainDistributionPipeline.yml)
[![DuckDB](https://img.shields.io/static/v1?label=duckdb&message=v1.5.4%2B&color=blue)](https://github.com/duckdb/duckdb/releases)
[![Community downloads per week](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fcommunity-extensions.duckdb.org%2Fdownloads-last-week.json&query=%24.marc21&label=downloads%2Fweek&color=brightgreen)](https://duckdb.org/community_extensions/download_metrics)

Read, write, validate, edit and analyze [MARC 21](https://www.loc.gov/marc/bibliographic/) bibliographic data within DuckDB. This extension has three broad areas of functionality:
* reading/profiling MARC from standard serializations: [ISO 2709](https://www.loc.gov/marc/specifications/specrecstruc.html) binary (UTF-8 and [MARC-8](https://www.loc.gov/marc/specifications/speccharintro.html), decoded to NFC with the full LC code tables), [MARCXML](https://www.loc.gov/standards/marcxml/), [MARC-in-JSON](https://www.loc.gov/standards/mij/), breaker text (`.mrk`) and Aleph sequential — into a nested per-record schema or one row per subfield — plus live retrieval over SRU, OAI-PMH and [Z39.50](https://www.loc.gov/z3950/agency/) with a built-in dependency-free client
* writing any of those formats back with `COPY`, including a complete UTF-8 ↔ MARC-8 crosswalk (ANSEL, Cyrillic, Greek, Hebrew, Arabic, EACC with escape designations)
* cataloging-grade querying, validation and editing: [MARCspec](https://marcspec.github.io/MARCspec/) addressing, structural and [Avram](https://format.gbv.de/schema/avram/specification)-schema validation with embedded MARC 21 rulepacks, record editing/merge/diff, identifier and NACO normalization, deduplication, QA reports, Dublin Core / MODS crosswalks and a [FOLIO](https://folio.org/) connector

The implementation is 100% C++ so as to leverage the speed and power of DuckDB. Gzip compression and glob patterns are supported for reads (for example `catalogue/*.mrc.gz`). Queries parallelize across and within files. Character decodings are skipped when selected columns do not require them.

The extension is built from scratch and cleanly licensed: parsers, MARC-8 tables and writers derive from ISO 2709 and the Library of Congress specifications only, not previous software. When similar open source software is available, differential fuzzing verifies cleanness. `read_z3950` requires OS-level networking and is not available in WASM.

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
