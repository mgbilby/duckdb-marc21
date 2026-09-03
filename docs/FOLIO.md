# Using `marc` as a FOLIO connector

The extension runs standalone, but pairs with DuckDB's standard connectivity
to act as a read-side connector for FOLIO's Source Record Storage (SRS).

## Live SRS analytics over an ATTACHed FOLIO database

FOLIO stores source MARC as JSONB (`parsedRecord` content) in PostgreSQL.
DuckDB's `postgres` extension attaches the tenant database; `marc_parse_json`
turns each SRS row into the nested record shape every `marc_*` function
understands.

```sql
INSTALL postgres; LOAD postgres; LOAD marc21;
ATTACH 'host=folio-db dbname=okapi user=folio_ro' AS folio (TYPE postgres, READ_ONLY);

-- One tenant's marc_records_lb: validate every source record in place
WITH src AS (
    SELECT id, marc_parse_json(content::VARCHAR) AS rec
    FROM folio.<tenant>_mod_source_record_storage.marc_records_lb
)
SELECT id, marc_validate(rec.leader, rec.fields) AS violations
FROM src
WHERE len(marc_validate(rec.leader, rec.fields)) > 0;
```

`marc_parse_json` accepts the raw parsedRecord content, the
`{"content": {...}}` wrapper, and the full `{"parsedRecord": {...}}`
envelope, so it works against `marc_records_lb.content` directly or against
API responses saved from `/source-storage/records`.

## Without database credentials

Records exported through the FOLIO APIs (Okapi/Kong) are MARC-in-JSON;
save or stream them and read with `read_marcjson(...)` (NDJSON supported).
`srs_marc` data-export files (`.mrc`) read with `read_marc(...)`.

## Preparing files for data-import

Before loading vendor files into FOLIO, quality-gate them here: validate
(`marc_validate`, `marc_validate_avram`), normalise identifiers
(`marc_isbn13`, `marc_oclc`), dedupe on `marc_matchkey`, batch-edit with the
`marc_set_*`/`marc_remove_*`/`marc_merge` functions, and write UTF-8 ISO 2709
with `COPY ... (FORMAT marc)` — FOLIO data-import expects UTF-8 (leader/09
`a`), which the writer always produces in the default encoding.
