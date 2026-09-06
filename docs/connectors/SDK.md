# Add your own ILS connector

A connector here is four small artifacts, no C++: a URL-builder macro, a
saved response fixture, a sqllogictest, and an auth secret recipe. This page
is the checklist the built-in connectors (`src/macros/ils.sql`) followed.

## 1. Find the record-retrieval endpoint

You need an HTTP GET that returns MARC for one record or one page of
records, in either:

* **MARCXML** — any envelope works: `read_marcxml` surfaces every
  `<record>` element (namespaces ignored, unknown wrappers skipped), so
  SRU, OAI-PMH, Atom feeds, vendor `<bib>`-style envelopes are all
  transparent. If the platform speaks SRU or OAI-PMH, you may not need a
  new macro at all — `marc_readsru(base, query)` / `marc_readoai(base)`
  already compose those.
* **MARC-in-JSON** — `read_marcjson` takes a record object, an array of
  them, or NDJSON, and per object unwraps `{"parsedRecord": {...}}` and
  `{"content": {...}}`. It does **not** unwrap other collection wrappers
  (`{"records": [...]}`, `{"sourceRecords": [...]}`): prefer a
  single-record endpoint, or split the wrapper with DuckDB's `json`
  extension and hand each element to `marc_parse_json`.

Endpoints returning binary MARC also work (`read_marc` over httpfs), as do
Z39.50 targets (`read_z3950`, no URL macro needed).

## 2. Write the URL-builder macro

Follow the `marc_readsru` style: a table macro that composes the endpoint
path and delegates to the reader. In a session or an init script:

```sql
CREATE OR REPLACE MACRO marc_readmyils(base, record_id) AS TABLE
SELECT * FROM read_marcxml(base || '/api/records/' || record_id || '/marcxml');
```

Conventions worth copying:

* `base` is the bare origin (`https://ils.example`), the macro owns the
  path — callers never assemble paths.
* `url_encode()` every free-text parameter (see `marc_readsru`'s `query_`);
  IDs that are digits/UUIDs can concatenate directly.
* Optional knobs are named parameters with defaults
  (`max_records := 50`), so calls stay one-liners.
* Credentials do *not* become parameters unless the platform only accepts
  them in the URL (Alma's `apikey :=` is the exception that proves it).

Contributing upstream: drop the macros in a new self-contained
`src/macros/<platform>.sql` — every file there is embedded and registered at
`LOAD` time in sorted filename order after `src/macros.sql` (see
`src/macros/README.md`); never edit another area's file.

## 3. Craft a fixture and a test

Save one real (anonymized) response as `test/data/sample_myils.xml` (or
`.json`) — keep the envelope exactly as the API sends it, because the
envelope is what the fixture is testing. Then a sqllogictest,
`test/sql/marc_myils.test`, that exercises the macro's reader path over the
fixture (URL builders themselves cannot fetch in CI, so assert the macro
exists and read the fixture through the same reader):

```
# name: test/sql/marc_myils.test
# group: [marc]

require marc21

query I
SELECT count(*) FROM duckdb_functions() WHERE function_name = 'marc_readmyils';
----
1

query II
SELECT control_number, value FROM read_marcxml('test/data/sample_myils.xml')
WHERE tag = '245' AND code = 'a';
----
myils-1	Expected title /
```

Worth asserting, from experience with the built-in fixtures: record count
(envelope metadata must not create phantom records), a value that appears
both in envelope metadata and in the record (must surface exactly once),
and any platform-reserved field (FOLIO `999 ff`, Koha `999 $c`).

## 4. Auth secret recipe

Document one `CREATE SECRET` per environment, scoped to the host so the
credentials apply to exactly the macro's URLs (syntax as of DuckDB 1.5):

```sql
CREATE SECRET myils (
    TYPE http,
    EXTRA_HTTP_HEADERS MAP {'Accept': 'application/xml', 'X-API-Key': '...'},
    -- or: BEARER_TOKEN '...'
    SCOPE 'https://ils.example'
);
```

If the platform needs a login POST to mint the token, say so and show the
`curl` — DuckDB only GETs, and pretending otherwise is how connectors rot.

## 5. Tell the write-back truth

Finish the platform page with the honest write story: `COPY ... (FORMAT
marc | marcxml | marcjson)` to a file, then *name the platform's import
pipeline* that loads it (Data Import, import profiles, staged import, Data
Sync, catalogload...), including what the pipeline matches on — that match
key is the difference between an update and a duplicate.
